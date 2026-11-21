import Foundation
import Testing
import TuyaLocal

@testable import catLight

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlight-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test func missingFileYieldsDefaultsWithTheEightDefaultFavorites() {
        let store = ConfigStore(fileURL: tempDir().appendingPathComponent("config.json"))
        let config = store.load()
        #expect(config.lights.isEmpty)
        #expect(config.selection == nil)
        #expect(config.favorites.colors == Favorites.defaultColors)
        #expect(config.preferences.launchAtLogin)
    }

    @Test func saveLoadRoundTrip() throws {
        let store = ConfigStore(fileURL: tempDir().appendingPathComponent("sub/config.json"))
        var config = AppConfig()
        config.lights = [
            Light(
                id: "bf01", name: "Fita LED Mesa", ip: "192.168.0.20", version: .v34, profile: .v2, kelvinMin: 2000, kelvinMax: 7000,
                productID: "p1"),
            Light(id: "bf02", name: "Lâmpada Estúdio"),
        ]
        config.selection = .all
        config.favorites.save("#12AB34")
        config.lastKnownState["bf01"] = LightState(
            power: true, mode: .color, hsv: HSV(h: 120, s: 800, v: 700), whiteBrightness: 400, temp: 250)
        config.preferences.launchAtLogin = false
        try store.save(config)
        #expect(store.load() == config)
    }

    @Test func corruptFileIsSetAsideAndDefaultsReturned() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: url)
        let config = ConfigStore(fileURL: url).load()
        #expect(config == AppConfig())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("config.corrupt-") })
        #expect(!files.contains("config.json"))
        // A fresh save works afterwards.
        try ConfigStore(fileURL: url).save(config)
        #expect(ConfigStore(fileURL: url).load() == config)
    }

    @Test func selectionSurvivesAReload() throws {
        let url = tempDir().appendingPathComponent("config.json")
        for selection in [LightSelection.all, .light("bf02")] {
            var config = AppConfig()
            config.selection = selection
            try ConfigStore(fileURL: url).save(config)
            #expect(ConfigStore(fileURL: url).load().selection == selection)
        }
    }

    @Test func configFileNeverContainsAKey() throws {
        let url = tempDir().appendingPathComponent("config.json")
        var config = AppConfig()
        config.lights = [Light(id: "bf01", name: "Luz")]
        try ConfigStore(fileURL: url).save(config)
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        #expect(!text.contains("localkey") && !text.contains("local_key") && !text.contains("secret"))
    }
}

@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {
    @Test func saveReadUpdateDelete() throws {
        let store = KeychainStore(service: "com.catlight.tests.\(UUID().uuidString)")
        let account = SecretAccount.localKey("bf01")
        defer { try? store.delete(account: account) }
        #expect(try store.read(account: account) == nil)
        try store.save("0123456789abcdef", account: account)
        #expect(try store.read(account: account) == "0123456789abcdef")
        try store.save("fedcba9876543210", account: account)  // update
        #expect(try store.read(account: account) == "fedcba9876543210")
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account)  // deleting a missing item is fine
    }

    @Test func accountNamesFollowTheDesign() {
        #expect(SecretAccount.localKey("abc") == "localkey:abc")
        #expect(SecretAccount.cloudSecret("id1") == "tuya-cloud:id1")
    }
}

@Suite("Favorites")
struct FavoritesTests {
    @Test func defaultsAreTheEightColorsWithCount8of12() {
        let f = Favorites()
        #expect(f.colors == ["#0A84FF", "#BF5AF2", "#FF375F", "#FF9F0A", "#30D158", "#64D2FF", "#FF453A", "#FFD60A"])
        #expect(f.countLabel == "8/12")
    }

    @Test func saveNewColorGoesFirst() {
        var f = Favorites()
        #expect(f.save("#12AB34") == .added)
        #expect(f.colors.first == "#12AB34")
        #expect(f.count == 9)
    }

    @Test func duplicateIsNotAddedAndReported() {
        var f = Favorites()
        #expect(f.save("#0A84FF") == .alreadySaved)
        #expect(f.save("0a84ff") == .alreadySaved)  // case/prefix-insensitive
        #expect(f.colors == Favorites.defaultColors)
    }

    @Test func fullListDropsTheOldest() {
        var f = Favorites()
        for hex in ["#000001", "#000002", "#000003", "#000004"] { f.save(hex) }
        #expect(f.count == 12 && f.countLabel == "12/12")
        let oldest = f.colors.last!
        #expect(f.save("#ABCDEF") == .added)
        #expect(f.colors.first == "#ABCDEF")
        #expect(f.count == 12)
        #expect(!f.colors.contains(oldest))
    }

    @Test func deleteRemovesAndEmptyListIsEmpty() {
        var f = Favorites()
        f.delete("#30D158")
        #expect(!f.contains("#30D158") && f.count == 7)
        for c in f.colors { f.delete(c) }
        #expect(f.isEmpty && f.count == 0)
    }

    @Test func invalidHexIsIgnored() {
        var f = Favorites()
        #expect(f.save("#ZZ12") == .alreadySaved)
        #expect(f.count == 8)
    }

    @Test func persistsThroughConfigStore() throws {
        let url = tempDir().appendingPathComponent("config.json")
        var config = AppConfig()
        config.favorites.save("#12AB34")
        try ConfigStore(fileURL: url).save(config)
        #expect(ConfigStore(fileURL: url).load().favorites.colors.first == "#12AB34")
    }
}
