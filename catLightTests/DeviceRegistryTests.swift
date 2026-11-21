import Foundation
import Testing
import TuyaLocal

@testable import catLight

@MainActor
@Suite("DeviceRegistry")
struct DeviceRegistryTests {
    func makeRegistry() -> (DeviceRegistry, FakeManager, InMemorySecretStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlight-\(UUID().uuidString)/config.json")
        let secrets = InMemorySecretStore()
        let manager = FakeManager()
        return (DeviceRegistry(store: ConfigStore(fileURL: url), secrets: secrets, manager: manager), manager, secrets, url)
    }

    func draft(name: String = "Fita LED Mesa", id: String = "bf01", key: String = "0123456789abcdef") -> LightDraft {
        LightDraft(name: name, deviceID: id, localKey: key)
    }

    @Test func addWithoutIPStoresLightAndStartsConnection() async throws {
        let (registry, manager, secrets, _) = makeRegistry()
        let light = try await registry.add(draft())
        #expect(registry.lights == [light])
        #expect(light.ip == nil)
        #expect(try secrets.read(account: "localkey:bf01") == "0123456789abcdef")
        let added = await manager.added
        #expect(added.count == 1 && added[0].deviceID == "bf01" && added[0].host == "" && added[0].localKey == "0123456789abcdef")
        #expect(registry.config.selection == .light("bf01"))  // first light becomes active
    }

    @Test(arguments: [
        (LightDraft(name: "", deviceID: "x", localKey: "0123456789abcdef"), LightDraft.Field.name),
        (LightDraft(name: "n", deviceID: " ", localKey: "0123456789abcdef"), LightDraft.Field.deviceID),
        (LightDraft(name: "n", deviceID: "x", localKey: ""), LightDraft.Field.localKey),
        (LightDraft(name: "n", deviceID: "x", localKey: "tooshort"), LightDraft.Field.localKey),
    ])
    func missingOrInvalidFieldIsRejectedAndHighlighted(draft: LightDraft, field: LightDraft.Field) async throws {
        let (registry, manager, secrets, url) = makeRegistry()
        await #expect(throws: LightValidationError(fields: [field])) { try await registry.add(draft) }
        #expect(registry.lights.isEmpty)
        #expect(secrets.accounts.isEmpty)
        #expect(await manager.added.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func allMissingFieldsAreReportedTogether() async throws {
        let (registry, _, _, _) = makeRegistry()
        await #expect(throws: LightValidationError(fields: [.name, .deviceID, .localKey])) { try await registry.add(LightDraft()) }
    }

    @Test func configFileHasNoKeyAfterAddingALight() async throws {
        let (registry, _, _, url) = makeRegistry()
        try await registry.add(draft(key: "SECRETKEY0123456"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("SECRETKEY0123456"))
        #expect(text.contains("bf01"))
    }

    @Test func removalClosesConnectionAndDeletesKeychainEntry() async throws {
        let (registry, manager, secrets, _) = makeRegistry()
        try await registry.add(draft(id: "a"))
        try await registry.add(draft(name: "Outra", id: "b", key: "fedcba9876543210"))
        await registry.remove(id: "a")
        #expect(registry.lights.map(\.id) == ["b"])
        #expect(await manager.removed == ["a"])
        #expect(try secrets.read(account: "localkey:a") == nil)
        #expect(try secrets.read(account: "localkey:b") == "fedcba9876543210")
        #expect(registry.config.selection == .light("b"))  // selection moved off the removed light
        await registry.remove(id: "b")
        #expect(registry.config.selection == nil)
    }

    @Test func removalOfRealManagerShutsTheConnectionDown() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlight-\(UUID().uuidString)/config.json")
        let manager = DeviceManager(connector: { _, _, _ in throw TuyaError.timeout })
        let registry = DeviceRegistry(store: ConfigStore(fileURL: url), secrets: InMemorySecretStore(), manager: manager)
        try await registry.add(draft())
        #expect(await manager.deviceIDs == ["bf01"])
        await registry.remove(id: "bf01")
        #expect(await manager.deviceIDs.isEmpty)
        await manager.shutdown()
    }

    @Test func editUpdatesFieldsAddressAndKey() async throws {
        let (registry, manager, secrets, _) = makeRegistry()
        try await registry.add(draft())
        var edit = draft(name: "Mesa")
        edit.ip = "192.168.0.31"
        edit.version = .v34
        edit.localKey = "fedcba9876543210"
        try await registry.update(id: "bf01", with: edit)
        let light = registry.lights[0]
        #expect(light.name == "Mesa" && light.ip == "192.168.0.31" && light.version == .v34)
        #expect(try secrets.read(account: "localkey:bf01") == "fedcba9876543210")
        #expect(await manager.addressUpdates.map(\.1) == ["192.168.0.31"])
        #expect(await manager.keyUpdates.map(\.1) == ["fedcba9876543210"])
    }

    @Test func editWithBlankKeyKeepsTheExistingKey() async throws {
        let (registry, manager, secrets, _) = makeRegistry()
        try await registry.add(draft())
        var edit = draft(name: "Renamed", key: "")
        edit.deviceID = "ignored"
        try await registry.update(id: "bf01", with: edit)
        #expect(registry.lights[0].name == "Renamed" && registry.lights[0].id == "bf01")
        #expect(try secrets.read(account: "localkey:bf01") == "0123456789abcdef")
        #expect(await manager.keyUpdates.isEmpty)
    }

    @Test func startAllRestoresConnectionsFromKeychainAndConfig() async throws {
        let (registry, _, secrets, url) = makeRegistry()
        try await registry.add(draft())
        let manager2 = FakeManager()
        let reloaded = DeviceRegistry(store: ConfigStore(fileURL: url), secrets: secrets, manager: manager2)
        await reloaded.startAll()
        #expect(await manager2.added.map(\.deviceID) == ["bf01"])
        #expect(await manager2.added.first?.localKey == "0123456789abcdef")
    }

    // 6.5
    @Test func activeSelectionPersistsAcrossReload() async throws {
        let (registry, _, secrets, url) = makeRegistry()
        try await registry.add(draft(id: "a"))
        try await registry.add(draft(name: "B", id: "b", key: "fedcba9876543210"))
        try registry.setSelection(.light("b"))
        #expect(DeviceRegistry(store: ConfigStore(fileURL: url), secrets: secrets, manager: FakeManager()).config.selection == .light("b"))
        try registry.setSelection(.all)
        #expect(DeviceRegistry(store: ConfigStore(fileURL: url), secrets: secrets, manager: FakeManager()).config.selection == .all)
        try registry.setSelection(.light("does-not-exist"))  // ignored
        #expect(registry.config.selection == .all)
    }
}
