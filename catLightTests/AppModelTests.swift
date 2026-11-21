import Foundation
import Testing
import TuyaLocal

@testable import catLight

/// Polls on the main actor until `condition` holds (real time, bounded).
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
struct Harness {
    let model: AppModel
    let registry: DeviceRegistry
    let manager: FakeManager
    let url: URL

    static func make(lights: [(String, String)] = [("a", "Fita LED Mesa")], seed: ((inout AppConfig) -> Void)? = nil, start: Bool = true)
        async throws -> Harness
    {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlight-\(UUID().uuidString)/config.json")
        let store = ConfigStore(fileURL: url)
        if let seed {
            var c = AppConfig()
            seed(&c)
            try store.save(c)
        }
        let manager = FakeManager()
        let secrets = InMemorySecretStore()
        let registry = DeviceRegistry(store: store, secrets: secrets, manager: manager)
        for (id, name) in lights { try await registry.add(LightDraft(name: name, deviceID: id, localKey: "0123456789abcdef")) }
        let model = AppModel(registry: registry, manager: manager, persistDelay: .milliseconds(20))
        if start { await model.start() }
        return Harness(model: model, registry: registry, manager: manager, url: url)
    }

    func connected(_ id: String, dps: DPMap = FakeDefaults.v2On) async {
        await manager.emit(.status(deviceID: id, .connected))
        await manager.emit(.state(deviceID: id, ReportedState(dps: dps)))
        _ = await eventually { model.statuses[id] == .connected && !(model.states[id]?.power == nil) }
        try? await Task.sleep(for: .milliseconds(30))
    }

    func patches() async -> [(patch: DPMap, ids: [String])] { await manager.patches }
}

enum FakeDefaults {
    static let v2On: DPMap = [20: .bool(true), 21: .string("white"), 22: .int(600), 23: .int(300), 24: .string("0078032003e8")]
    static let v2Off: DPMap = [20: .bool(false), 21: .string("white"), 22: .int(600), 23: .int(300), 24: .string("0078032003e8")]
    static let legacyOn: DPMap = [1: .bool(true), 2: .string("white"), 3: .int(200), 4: .int(100), 5: .string("00ff000078ffff")]
}

@MainActor
@Suite("AppModel")
struct AppModelTests {
    @Test func startBringsUpConnectionsForStoredLights() async throws {
        let h = try await Harness.make(lights: [("a", "A"), ("b", "B")], start: false)
        let manager2 = FakeManager()
        let model2 = AppModel(
            registry: DeviceRegistry(store: ConfigStore(fileURL: h.url), secrets: InMemorySecretStore(), manager: manager2),
            manager: manager2)
        _ = model2
        // registry from the harness already started them on add; a fresh start() re-adds from Keychain-backed config:
        await h.model.start()
        #expect(await h.manager.added.map(\.deviceID).sorted() == ["a", "a", "b", "b"])  // once on add, once on start
    }

    @Test func statusAndStateUpdatesReachTheDisplay() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: [20: .bool(true), 21: .string("colour"), 22: .int(600), 23: .int(300), 24: .string("0078032003e8")])
        let m = h.model
        #expect(m.headerStatus == .connected && m.isDisplayStateCurrent)
        #expect(m.displayState.power && m.displayState.mode == .color)
        #expect(m.displayState.hsv == HSV(h: 120, s: 800, v: 1000))
        #expect(m.headerTitle == "Fita LED Mesa")
        // A later push (change from the phone app) updates the display.
        await h.manager.emit(.state(deviceID: "a", ReportedState(dps: [24: .string("00780320012c")])))
        #expect(await eventually { m.displayState.hsv.v == 300 })
    }

    @Test func powerIntentSendsOnlyTheSwitch() async throws {
        let h = try await Harness.make()
        await h.connected("a")
        h.model.setPower(false)
        #expect(await eventually { await h.patches().count == 1 })
        let p = await h.patches()[0]
        #expect(p.patch == [20: .bool(false)] && p.ids == ["a"])
        #expect(h.model.displayState.power == false)  // optimistic
    }

    @Test func colorChangeOnAnOffLightTurnsItOn() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2Off)
        h.model.setColor(hue: 30, saturation: 900)
        #expect(await eventually { await h.patches().count == 1 })
        let patch = await h.patches()[0].patch
        #expect(patch[20] == .bool(true) && patch[21] == .string("colour"))
        #expect(h.model.displayState.power && h.model.displayState.mode == .color)
    }

    @Test func hexEntryAcceptsValidAndRejectsInvalid() async throws {
        let h = try await Harness.make()
        await h.connected("a")
        #expect(h.model.setColor(hex: "#ZZ12") == false)
        #expect(await h.patches().isEmpty)
        #expect(h.model.setColor(hex: "#FF375F"))
        #expect(await eventually { await h.patches().count == 1 })
        #expect(h.model.currentHex == "#FF375F")
        #expect(h.model.displayState.mode == .color)
    }

    @Test func brightnessAndTemperatureFollowTheCurrentMode() async throws {
        let h = try await Harness.make()
        await h.connected("a")  // white mode
        h.model.setBrightness(percent: 40)
        h.model.setPreset(.vela)  // 2400K < 2700K -> clamped
        #expect(await eventually { await h.patches().count == 2 })
        let patches = await h.patches().map(\.patch)
        #expect(patches[0] == [22: .int(400)])
        #expect(patches[1] == [21: .string("white"), 23: .int(0)])
        #expect(h.model.currentKelvin == 2700)
    }

    @Test func allLightsSendsEachLightItsOwnProfileSpecificPatch() async throws {
        let h = try await Harness.make(lights: [("a", "V2 strip"), ("b", "Legacy bulb")])
        h.registry.record(version: nil, profile: .legacy, for: "b")
        h.model.select(.all)
        await h.connected("a")
        await h.connected("b", dps: FakeDefaults.legacyOn)
        h.model.setColor(hue: 0, saturation: 1000)
        #expect(await eventually { await h.patches().count == 2 })
        let byID = Dictionary(uniqueKeysWithValues: await h.patches().map { ($0.ids[0], $0.patch) })
        #expect(byID["a"]?[21] == .string("colour") && byID["a"]?[24] != nil)  // DPs 20–24
        #expect(byID["b"]?[2] == .string("colour") && byID["b"]?[5] != nil)  // DPs 1–5
        #expect(h.model.headerTitle == "Todas as luzes")
    }

    @Test func allLightsDisplaysWhatTheUserSetThenFollowsTheFirstConnectedLight() async throws {
        let h = try await Harness.make(lights: [("a", "A"), ("b", "B")])
        h.model.select(.all)
        await h.connected("b", dps: FakeDefaults.v2On)  // only the second light is connected
        #expect(h.model.displayState.power)  // state of the first connected light
        h.model.setColor(hue: 25, saturation: 950)
        #expect(h.model.displayState.mode == .color && h.model.displayState.hsv.h == 25)
    }

    @Test func offlineLightShowsLastKnownStateMarkedNotCurrent() async throws {
        let cached = LightState(power: true, mode: .color, hsv: HSV(h: 200, s: 700, v: 800))
        let h = try await Harness.make(seed: { $0.lastKnownState["a"] = cached })
        // The harness adds "a" after seeding, keeping the seeded cache.
        #expect(h.model.displayState == cached)
        #expect(h.model.isDisplayStateCurrent == false)
        #expect(h.model.indicatorColor == nil)  // gray while offline
        await h.connected("a", dps: FakeDefaults.v2On)
        #expect(h.model.isDisplayStateCurrent)
        #expect(h.model.indicatorColor != nil)
    }

    @Test func indicatorIsGrayWhenTheLightIsOff() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2Off)
        #expect(h.model.indicatorColor == nil)
    }

    @Test func reportsAreHeldDuringADragAndAppliedAfterwards() async throws {
        let h = try await Harness.make()
        await h.connected("a")
        let m = h.model
        m.beginEditing(.brightness)
        m.setBrightness(percent: 30)
        await h.manager.emit(.state(deviceID: "a", ReportedState(dps: [22: .int(1000)])))  // stale echo
        try await Task.sleep(for: .milliseconds(100))
        #expect(m.displayState.brightnessPercent == 30)  // not overwritten mid-drag
        m.endEditing(.brightness)
        #expect(await eventually { m.displayState.brightnessPercent == 100 })  // reality adopted after release
    }

    @Test func applyFailedAndAppliedEventsDriveTheIndicator() async throws {
        let h = try await Harness.make()
        await h.manager.emit(.event(deviceID: "a", .applyFailed))
        #expect(await eventually { h.model.hasUnappliedChange })
        await h.manager.emit(.event(deviceID: "a", .applied))
        #expect(await eventually { !h.model.hasUnappliedChange })
    }

    @Test func profileIsDetectedFromTheFirstReportAndUsedForPatches() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.legacyOn)
        #expect(h.registry.lights[0].profile == .legacy)
        h.model.setPower(false)
        #expect(await eventually { await h.patches().count == 1 })
        #expect(await h.patches()[0].patch == [1: .bool(false)])
    }

    @Test func versionResolvedIsPersisted() async throws {
        let h = try await Harness.make()
        await h.manager.emit(.event(deviceID: "a", .versionResolved(.v34)))
        #expect(await eventually { h.registry.lights[0].version == .v34 })
    }

    @Test func selectionChangesAndPersists() async throws {
        let h = try await Harness.make(lights: [("a", "A"), ("b", "B")])
        h.model.select(.light("b"))
        #expect(h.model.headerTitle == "B" && h.model.targetIDs == ["b"])
        #expect(h.registry.config.selection == .light("b"))
        h.model.select(.all)
        #expect(h.model.targetIDs == ["a", "b"])
    }

    @Test func removingALightUpdatesTheModel() async throws {
        let h = try await Harness.make(lights: [("a", "A"), ("b", "B")])
        await h.model.removeLight(id: "a")
        #expect(h.model.lights.map(\.id) == ["b"])
        #expect(h.model.selection == .light("b"))
        #expect(await h.manager.removed == ["a"])
    }

    @Test func popoverWakeAndNetworkEventsTriggerReconnects() async throws {
        let h = try await Harness.make()
        h.model.popoverWillShow()
        h.model.systemDidWake()
        h.model.networkDidChange()
        #expect(await eventually { await h.manager.refreshAllCount == 1 })
        #expect(await eventually { await h.manager.reconnectAllCount == 2 })
    }

    @Test func lastKnownStateIsPersistedForTheNextLaunch() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2On)
        h.model.persistNow()
        let reloaded = ConfigStore(fileURL: h.url).load()
        #expect(reloaded.lastKnownState["a"]?.power == true)
    }

    @Test func launchAtLoginPreferencePersists() async throws {
        let h = try await Harness.make()
        h.model.setLaunchAtLogin(false)
        #expect(ConfigStore(fileURL: h.url).load().preferences.launchAtLogin == false)
    }
}

@MainActor
@Suite("Scenes in the app model")
struct SceneModelTests {
    func scene(_ name: String) -> LightScene { LightScene.all.first { $0.name == name }! }

    @Test func applyingASceneIsOneDesiredStatePatch() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2Off)
        h.model.applyScene(scene("Cyberpunk"))
        #expect(await eventually { await h.patches().count == 1 })
        let patch = await h.patches()[0].patch
        #expect(patch == [20: .bool(true), 21: .string("colour"), 24: .string("0127" + "0398" + "0384")])
        #expect(h.model.displayState.mode == .color && h.model.displayState.power)  // Luz tab reflects it
        #expect(h.model.activeSceneID == "cyberpunk")
    }

    @Test func whiteSceneOnA2700KLightClamps() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2On)
        h.model.applyScene(scene("Leitura Noturna"))
        #expect(await eventually { await h.patches().count == 1 })
        #expect(await h.patches()[0].patch[23] == .int(0))
        #expect(h.model.currentKelvin == 2700 && h.model.displayState.brightnessPercent == 45)
        #expect(h.model.activeSceneID == "leitura-noturna")
    }

    @Test func everySceneIsRecognizedAfterItIsApplied() async throws {
        for scene in LightScene.all {
            let h = try await Harness.make()
            await h.connected("a", dps: FakeDefaults.v2Off)
            h.model.applyScene(scene)
            #expect(h.model.activeSceneID == scene.id, "\(scene.name)")
        }
    }

    @Test func highlightClearsWhenTheLightIsChangedAnyOtherWay() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2On)
        h.model.applyScene(scene("Pôr do Sol"))
        #expect(h.model.activeSceneID == "por-do-sol")
        h.model.setBrightness(percent: 40)
        #expect(h.model.activeSceneID == nil)
    }

    @Test func noSceneIsHighlightedWhileOff() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2On)
        h.model.applyScene(scene("Modo Cinema"))
        h.model.setPower(false)
        #expect(h.model.activeSceneID == nil)
    }
}

@MainActor
@Suite("Favorites in the app model")
struct FavoritesModelTests {
    @Test func saveCurrentColorAddsFirstAndPersists() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2On)
        h.model.setColor(hex: "#12AB34")
        #expect(h.model.saveFavorite() == .added)
        #expect(h.model.favorites.colors.first == "#12AB34" && h.model.favorites.count == 9)
        #expect(ConfigStore(fileURL: h.url).load().favorites.colors.first == "#12AB34")
        #expect(h.model.saveFavorite() == .alreadySaved)
        #expect(h.model.favorites.count == 9)
    }

    @Test func applyFavoriteSetsColorModeAndTurnsLightOn() async throws {
        let h = try await Harness.make()
        await h.connected("a", dps: FakeDefaults.v2Off)
        h.model.applyFavorite("#FF9F0A")
        #expect(await eventually { await h.patches().count == 1 })
        let patch = await h.patches()[0].patch
        #expect(patch[20] == .bool(true) && patch[21] == .string("colour"))
        #expect(h.model.currentHex == "#FF9F0A")
    }

    @Test func deleteDoesNotChangeTheLight() async throws {
        let h = try await Harness.make()
        await h.connected("a")
        h.model.deleteFavorite("#30D158")
        #expect(!h.model.favorites.contains("#30D158") && h.model.favorites.count == 7)
        #expect(await h.patches().isEmpty)
        #expect(!ConfigStore(fileURL: h.url).load().favorites.contains("#30D158"))
    }

    @Test func favoritesSurviveARestart() async throws {
        let h = try await Harness.make()
        await h.connected("a")
        h.model.setColor(hex: "#12AB34")
        h.model.saveFavorite()
        let restarted = AppModel(
            registry: DeviceRegistry(store: ConfigStore(fileURL: h.url), secrets: InMemorySecretStore(), manager: FakeManager()),
            manager: FakeManager())
        #expect(restarted.favorites.colors.first == "#12AB34")
    }
}
