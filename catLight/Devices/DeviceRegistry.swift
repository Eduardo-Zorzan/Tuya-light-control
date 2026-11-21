import Foundation
import TuyaLocal

/// User input for adding or editing a light.
struct LightDraft: Equatable {
    var name = ""
    var deviceID = ""
    var localKey = ""
    var ip = ""
    var version: TuyaVersion?
    var kelvinMin = LightCodec.defaultKelvinRange.lowerBound
    var kelvinMax = LightCodec.defaultKelvinRange.upperBound
    var productID: String?

    enum Field: String, Hashable, Sendable { case name, deviceID, localKey, kelvinRange }

    /// Fields that fail validation. `requireKey: false` is used when editing (blank key = keep the current one).
    func invalidFields(requireKey: Bool = true) -> Set<Field> {
        var bad = Set<Field>()
        if name.trimmed.isEmpty { bad.insert(.name) }
        if deviceID.trimmed.isEmpty { bad.insert(.deviceID) }
        if requireKey, localKey.trimmed.isEmpty { bad.insert(.localKey) }
        if !localKey.trimmed.isEmpty, localKey.trimmed.utf8.count != 16 { bad.insert(.localKey) }
        if kelvinMin <= 0 || kelvinMax <= kelvinMin { bad.insert(.kelvinRange) }
        return bad
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct LightValidationError: Error, Equatable { let fields: Set<LightDraft.Field> }

/// Owns the persisted list of lights: validates input, keeps keys in the Keychain and the config free of
/// secrets, and starts/updates/stops the matching connection.
@MainActor
final class DeviceRegistry {
    private(set) var config: AppConfig
    private let store: ConfigStore
    private let secrets: SecretStore
    private let manager: any DeviceControlling

    init(store: ConfigStore, secrets: SecretStore, manager: any DeviceControlling) {
        self.store = store
        self.secrets = secrets
        self.manager = manager
        self.config = store.load()
    }

    var lights: [Light] { config.lights }

    /// Starts a connection for every stored light (keys come from the Keychain).
    func startAll() async {
        for light in config.lights {
            guard let key = (try? secrets.read(account: SecretAccount.localKey(light.id))) ?? nil else { continue }
            await manager.add(configuration(for: light, key: key))
        }
    }

    // MARK: Mutations

    @discardableResult
    func add(_ draft: LightDraft) async throws -> Light {
        let bad = draft.invalidFields()
        guard bad.isEmpty else { throw LightValidationError(fields: bad) }
        let id = draft.deviceID.trimmed
        let light = Light(
            id: id, name: draft.name.trimmed, ip: draft.ip.trimmed.nilIfEmpty, version: draft.version,
            kelvinMin: draft.kelvinMin, kelvinMax: draft.kelvinMax, productID: draft.productID)
        try secrets.save(draft.localKey.trimmed, account: SecretAccount.localKey(id))
        if let i = config.lights.firstIndex(where: { $0.id == id }) {
            config.lights[i] = light
        } else {
            config.lights.append(light)
        }
        if config.selection == nil { config.selection = .light(id) }
        config.preferences.setupCompleted = true
        try persist()
        await manager.add(configuration(for: light, key: draft.localKey.trimmed))
        return light
    }

    /// Edits name, IP, version, Kelvin range and (optionally) the key of an existing light.
    func update(id: String, with draft: LightDraft) async throws {
        guard let i = config.lights.firstIndex(where: { $0.id == id }) else { return }
        var edited = draft
        edited.deviceID = id
        let bad = edited.invalidFields(requireKey: false)
        guard bad.isEmpty else { throw LightValidationError(fields: bad) }
        var light = config.lights[i]
        light.name = draft.name.trimmed
        light.ip = draft.ip.trimmed.nilIfEmpty
        light.version = draft.version
        light.kelvinMin = draft.kelvinMin
        light.kelvinMax = draft.kelvinMax
        config.lights[i] = light
        try persist()
        if let host = light.ip { await manager.updateAddress(deviceID: id, host: host, version: light.version) }
        let newKey = draft.localKey.trimmed
        if !newKey.isEmpty {
            try secrets.save(newKey, account: SecretAccount.localKey(id))
            await manager.updateKey(deviceID: id, localKey: newKey)
        }
    }

    /// Replaces a stored key (cloud "refresh keys") and reconnects.
    func replaceKey(id: String, with key: String) async throws {
        guard config.lights.contains(where: { $0.id == id }), key.trimmed.utf8.count == 16 else { return }
        try secrets.save(key.trimmed, account: SecretAccount.localKey(id))
        await manager.updateKey(deviceID: id, localKey: key.trimmed)
    }

    /// Removes a light: closes its connection, deletes its Keychain entry and fixes the selection.
    func remove(id: String) async {
        await manager.remove(deviceID: id)
        try? secrets.delete(account: SecretAccount.localKey(id))
        config.lights.removeAll { $0.id == id }
        config.lastKnownState[id] = nil
        if config.selection == .light(id) { config.selection = config.lights.first.map { .light($0.id) } }
        if config.lights.isEmpty { config.selection = nil }
        try? persist()
    }

    func setSelection(_ selection: LightSelection) throws {
        switch selection {
        case .light(let id): guard config.lights.contains(where: { $0.id == id }) else { return }
        case .all: break
        }
        config.selection = selection
        try persist()
    }

    /// Records what discovery/connection learned about a light (version, profile) without touching secrets.
    func record(version: TuyaVersion?, profile: DPProfile?, for id: String) {
        guard let i = config.lights.firstIndex(where: { $0.id == id }) else { return }
        if let version { config.lights[i].version = version }
        if let profile { config.lights[i].profile = profile }
        try? persist()
    }

    func recordAddress(_ ip: String, for id: String) {
        guard let i = config.lights.firstIndex(where: { $0.id == id }) else { return }
        config.lights[i].ip = ip
        try? persist()
    }

    func mutateConfig(_ change: (inout AppConfig) -> Void) {
        change(&config)
        try? persist()
    }

    // MARK: Cloud credentials

    /// Remembers the Access ID/region and (if `secret` is given) stores the Access Secret in the Keychain.
    func rememberCloud(accessID: String, region: TuyaCloudRegion, secret: String?) {
        config.preferences.cloudAccessID = accessID
        config.preferences.cloudRegion = region
        if let secret, !secret.isEmpty { try? secrets.save(secret, account: SecretAccount.cloudSecret(accessID)) }
        try? persist()
    }

    func cloudSecret(accessID: String) -> String? {
        ((try? secrets.read(account: SecretAccount.cloudSecret(accessID))) ?? nil)
    }

    private func persist() throws { try store.save(config) }

    private func configuration(for light: Light, key: String) -> DeviceConfiguration {
        DeviceConfiguration(deviceID: light.id, host: light.ip ?? "", localKey: key, version: light.version)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
