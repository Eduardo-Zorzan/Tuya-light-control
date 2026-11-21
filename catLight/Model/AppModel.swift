import Foundation
import Observation
import TuyaLocal

/// Single source of truth for the UI. Consumes the connection layer's updates and turns user intents
/// into per-light datapoint patches (each light has its own profile and Kelvin range).
@MainActor
@Observable
final class AppModel {
    /// Controls that can be mid-drag; incoming reports for them are held back until the drag ends.
    enum EditingControl: Hashable { case colorWheel, brightness, temperature }

    // MARK: Observable state

    private(set) var lights: [Light] = []
    private(set) var selection: LightSelection?
    private(set) var statuses: [String: ConnectionStatus] = [:]
    private(set) var states: [String: LightState] = [:]
    /// Lights with a change that could not be applied (cleared when delivery succeeds).
    private(set) var applyFailed: Set<String> = []
    private(set) var favorites = Favorites()
    private(set) var preferences = Preferences()
    private(set) var discoveryUnavailable = false
    /// State the user last set while "all lights" is selected.
    private var allLightsState: LightState?
    private var editing: Set<EditingControl> = []
    private var heldReports: [String: DPMap] = [:]
    /// Exact hex the user last typed/picked: Tuya stores whole-degree hues, so it cannot be rebuilt from the light's state.
    private var picked: (hex: String, h: Int, s: Int)?

    // MARK: Dependencies

    @ObservationIgnored private let registry: DeviceRegistry
    @ObservationIgnored private let manager: any DeviceControlling
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var outboxTask: Task<Void, Never>?
    @ObservationIgnored private var outbox: AsyncStream<(DPMap, String)>.Continuation?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let persistDelay: Duration
    /// Fired once when the first light is added (used to turn launch at login on by default).
    @ObservationIgnored var onSetupCompleted: (() -> Void)?

    init(registry: DeviceRegistry, manager: any DeviceControlling, persistDelay: Duration = .seconds(1)) {
        self.registry = registry
        self.manager = manager
        self.persistDelay = persistDelay
        reloadFromRegistry()
        // Show the last known state immediately, marked as not current until the light connects.
        states = registry.config.lastKnownState
    }

    // MARK: Lifecycle

    /// Starts connections and begins consuming updates.
    func start() async {
        guard consumeTask == nil else { return }
        let (stream, cont) = AsyncStream.makeStream(of: (DPMap, String).self, bufferingPolicy: .unbounded)
        outbox = cont
        let manager = self.manager
        outboxTask = Task {
            for await (patch, id) in stream { await manager.setDesired(patch, for: [id]) }  // one at a time: keeps order
        }
        consumeTask = Task { [weak self] in
            guard let updates = self?.manager.updates else { return }
            for await update in updates { self?.handle(update) }
        }
        await registry.startAll()
    }

    func shutdown() async {
        consumeTask?.cancel()
        outbox?.finish()
        outboxTask?.cancel()
        saveTask?.cancel()
        persistNow()
        await manager.shutdown()
    }

    // MARK: Derived

    var hasLights: Bool { !lights.isEmpty }

    /// Lights the controls currently act on.
    var targetIDs: [String] {
        switch selection {
        case .light(let id): return lights.contains { $0.id == id } ? [id] : []
        case .all: return lights.map(\.id)
        case nil: return []
        }
    }

    var activeLight: Light? {
        if case .light(let id) = selection { return lights.first { $0.id == id } }
        return nil
    }

    var headerTitle: String { selection == .all ? "Todas as luzes" : (activeLight?.name ?? "catLight") }

    /// Status shown in the header: the single light's, or for "all" the best one (connected > connecting > worst).
    var headerStatus: ConnectionStatus {
        let ids = targetIDs
        let all = ids.map { statuses[$0] ?? .idle }
        if all.isEmpty { return .idle }
        if all.contains(where: \.isConnected) { return .connected }
        return all.first(where: { $0 == .connecting }) ?? all[0]
    }

    /// State the controls display.
    var displayState: LightState {
        switch selection {
        case .light(let id): return states[id] ?? LightState()
        case .all:
            if let allLightsState { return allLightsState }
            let firstConnected = lights.first { statuses[$0.id]?.isConnected == true }
            return (firstConnected ?? lights.first).flatMap { states[$0.id] } ?? LightState()
        case nil: return LightState()
        }
    }

    /// False while the displayed light(s) are not connected: the state shown is the last known one.
    var isDisplayStateCurrent: Bool { headerStatus.isConnected }
    var hasUnappliedChange: Bool { targetIDs.contains { applyFailed.contains($0) } }

    var kelvinRange: ClosedRange<Int> { (activeLight ?? lights.first)?.kelvinRange ?? LightCodec.defaultKelvinRange }

    /// Hex readout: hue and saturation at full value (brightness has its own slider).
    var currentHex: String {
        if displayState.mode == .white { return RGBColor(kelvin: currentKelvin).hex }
        let hsv = displayState.hsv
        if let picked, picked.h == hsv.h, picked.s == hsv.s { return picked.hex }
        return HSV(h: hsv.h, s: hsv.s, v: 1000).rgb.hex
    }
    var currentKelvin: Int { LightCodec(profile: .v2, kelvinRange: kelvinRange).kelvin(fromTemp: displayState.temp) }

    /// Color shown on the menu bar dot and emblem: the light color while on, `nil` (gray) when off or offline.
    var indicatorColor: RGBColor? {
        let s = displayState
        guard s.power, headerStatus.isConnected else { return nil }
        return s.mode == .color ? HSV(h: s.hsv.h, s: s.hsv.s, v: 1000).rgb : RGBColor(kelvin: currentKelvin)
    }

    /// The scene matching the current state, if any (so any other change clears the highlight).
    var activeSceneID: String? {
        let state = displayState
        guard state.power else { return nil }
        let codec = codec(for: targetIDs.first ?? "")
        return LightScene.all.first { Self.matches($0, state: state, codec: codec) }?.id
    }

    // MARK: Intents — lights

    func setPower(_ on: Bool) { send { intents, _ in intents.power(on) } }

    func setColor(hue: Int, saturation: Int) {
        picked = nil
        send { intents, state in intents.color(hue: hue, saturation: saturation, state: state) }
    }

    /// Sets the color from a typed hex code. Returns false (and changes nothing) for an invalid code.
    @discardableResult
    func setColor(hex: String) -> Bool {
        guard let rgb = RGBColor(hex: hex) else { return false }
        let hsv = rgb.hsv
        setColor(hue: hsv.h, saturation: hsv.s)
        picked = (rgb.hex, hsv.h, hsv.s)
        return true
    }

    func setBrightness(percent: Int) { send { intents, state in intents.brightness(percent: percent, state: state) } }
    func setTemperature(kelvin: Int) { send { intents, state in intents.temperature(kelvin: kelvin, state: state) } }
    func setPreset(_ preset: TemperaturePreset) { setTemperature(kelvin: preset.kelvin) }
    func setMode(_ mode: LightMode) { send { intents, state in intents.mode(mode, state: state) } }
    func applyScene(_ scene: LightScene) { send { intents, state in intents.scene(scene, state: state) } }

    // MARK: Intents — favorites

    @discardableResult
    func saveFavorite() -> Favorites.SaveResult {
        var f = favorites
        let result = f.save(currentHex)
        favorites = f
        if result == .added { registry.mutateConfig { $0.favorites = f } }
        return result
    }

    func applyFavorite(_ hex: String) { setColor(hex: hex) }

    func deleteFavorite(_ hex: String) {
        favorites.delete(hex)
        let f = favorites
        registry.mutateConfig { $0.favorites = f }
    }

    // MARK: Intents — selection, devices, settings

    func select(_ selection: LightSelection) {
        try? registry.setSelection(selection)
        allLightsState = nil
        reloadFromRegistry()
    }

    func addLight(_ draft: LightDraft) async throws {
        let wasEmpty = lights.isEmpty
        try await registry.add(draft)
        reloadFromRegistry()
        if wasEmpty { onSetupCompleted?() }
    }

    /// A discovery broadcast: if it is one of ours at a new address (DHCP), store it and reconnect there.
    func discovered(_ device: DiscoveredDevice) async {
        guard let light = lights.first(where: { $0.id == device.deviceID }) else { return }
        if light.ip != device.ip {
            registry.recordAddress(device.ip, for: light.id)
            reloadFromRegistry()
        }
        await manager.updateAddress(deviceID: light.id, host: device.ip, version: device.version)
    }

    func updateLight(id: String, with draft: LightDraft) async throws {
        try await registry.update(id: id, with: draft)
        reloadFromRegistry()
    }

    func removeLight(id: String) async {
        await registry.remove(id: id)
        statuses[id] = nil
        states[id] = nil
        applyFailed.remove(id)
        reloadFromRegistry()
    }

    func setLaunchAtLogin(_ on: Bool) {
        preferences.launchAtLogin = on
        let p = preferences
        registry.mutateConfig { $0.preferences = p }
    }

    // MARK: Cloud

    var savedCloud: (accessID: String, region: TuyaCloudRegion, secret: String?)? {
        guard let id = preferences.cloudAccessID else { return nil }
        return (id, preferences.cloudRegion ?? .westernAmerica, registry.cloudSecret(accessID: id))
    }

    func rememberCloud(accessID: String, region: TuyaCloudRegion, secret: String?) {
        registry.rememberCloud(accessID: accessID, region: region, secret: secret)
        reloadFromRegistry()
    }

    /// Adds lights picked from the cloud list (each with its local key).
    func importLights(_ devices: [CloudDevice]) async throws {
        for d in devices {
            try await addLight(LightDraft(name: d.name, deviceID: d.id, localKey: d.localKey, productID: d.productID))
        }
    }

    /// Re-fetches local keys for the registered lights; returns how many were updated.
    func refreshKeys(using client: TuyaCloudClient) async throws -> Int {
        let keys = try await client.refreshKeys(for: lights.map(\.id))
        for (id, key) in keys { try await registry.replaceKey(id: id, with: key) }
        return keys.count
    }

    /// True when a light cannot connect because macOS Local Network access was denied.
    var localNetworkDenied: Bool {
        lights.contains { if case .error(.localNetworkDenied, _)? = statuses[$0.id] { return true } else { return false } }
    }

    func setDiscoveryUnavailable(_ unavailable: Bool) { discoveryUnavailable = unavailable }

    // MARK: Drag handling

    /// A slider/wheel drag started: reports for the displayed light(s) are held back so they cannot fight the user.
    func beginEditing(_ control: EditingControl) { editing.insert(control) }

    func endEditing(_ control: EditingControl) {
        editing.remove(control)
        guard editing.isEmpty else { return }
        let held = heldReports
        heldReports = [:]
        for (id, dps) in held { applyReport(dps, to: id) }
    }

    // MARK: System events

    func popoverWillShow() { Task { await manager.refreshAll() } }
    func systemDidWake() { Task { await manager.reconnectAll() } }
    func networkDidChange() { Task { await manager.reconnectAll() } }

    // MARK: Updates

    private func handle(_ update: DeviceUpdate) {
        switch update {
        case .status(let id, let status):
            statuses[id] = status
        case .state(let id, let reported):
            if let light = lights.first(where: { $0.id == id }), light.profile == nil, let detected = DPProfile.detect(from: reported.dps) {
                registry.record(version: nil, profile: detected, for: id)
                reloadFromRegistry()
            }
            if !editing.isEmpty, targetIDs.contains(id) {
                heldReports[id, default: [:]].merge(reported.dps) { _, new in new }
            } else {
                applyReport(reported.dps, to: id)
            }
        case .event(let id, let event):
            switch event {
            case .applyFailed: applyFailed.insert(id)
            case .applied: applyFailed.remove(id)
            case .versionResolved(let v): registry.record(version: v, profile: nil, for: id)
            }
        }
    }

    private func applyReport(_ dps: DPMap, to id: String) {
        let codec = codec(for: id)
        states[id] = codec.decode(dps, over: states[id] ?? LightState())
        if selection == .all, targetIDs.first == id { allLightsState = nil }  // adopt reality unless the user just set something
        scheduleSave()
    }

    // MARK: Plumbing

    private func codec(for id: String) -> LightCodec {
        let light = lights.first { $0.id == id }
        return LightCodec(profile: light?.profile ?? .v2, kelvinRange: light?.kelvinRange ?? LightCodec.defaultKelvinRange)
    }

    /// Builds one patch per target light from its own profile/state, updates the display optimistically and queues delivery.
    private func send(_ build: (LightIntents, LightState) -> DPMap) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        for id in ids {
            let codec = codec(for: id)
            let state = states[id] ?? LightState()
            let patch = build(LightIntents(codec: codec), state)
            guard !patch.isEmpty else { continue }
            states[id] = codec.decode(patch, over: state)
            outbox?.yield((patch, id))
        }
        if selection == .all, let first = ids.first { allLightsState = states[first] }
        scheduleSave()
    }

    private func reloadFromRegistry() {
        lights = registry.lights
        selection = registry.config.selection
        favorites = registry.config.favorites
        preferences = registry.config.preferences
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = persistDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func persistNow() {
        let snapshot = states
        registry.mutateConfig { $0.lastKnownState = snapshot }
    }

    // MARK: Scene matching

    static func matches(_ scene: LightScene, state: LightState, codec: LightCodec) -> Bool {
        switch scene.setting {
        case .white(let kelvin, let percent):
            return state.mode == .white
                && abs(codec.kelvin(fromTemp: state.temp) - codec.clamp(kelvin: kelvin)) <= 8
                && abs(state.brightnessPercent - percent) <= 1
        case .color(let hue, let satPercent, let percent):
            let dh = abs(state.hsv.h - hue)
            return state.mode == .color && min(dh, 360 - dh) <= 2 && abs(state.hsv.s - satPercent * 10) <= 8
                && abs(state.brightnessPercent - percent) <= 1
        }
    }
}
