import Foundation
import TuyaLocal

/// A registered light. Never contains the local key: that lives in the Keychain.
struct Light: Codable, Equatable, Identifiable, Sendable {
    var id: String  // Tuya device id
    var name: String
    var ip: String?
    var version: TuyaVersion?
    var profile: DPProfile?
    var kelvinMin: Int
    var kelvinMax: Int
    var productID: String?

    init(
        id: String, name: String, ip: String? = nil, version: TuyaVersion? = nil, profile: DPProfile? = nil,
        kelvinMin: Int = LightCodec.defaultKelvinRange.lowerBound, kelvinMax: Int = LightCodec.defaultKelvinRange.upperBound,
        productID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ip = ip
        self.version = version
        self.profile = profile
        self.kelvinMin = kelvinMin
        self.kelvinMax = kelvinMax
        self.productID = productID
    }

    var kelvinRange: ClosedRange<Int> { min(kelvinMin, kelvinMax)...max(kelvinMin, kelvinMax) }
}

/// Which light(s) the controls act on.
enum LightSelection: Codable, Hashable, Sendable {
    case light(String)
    case all
}

struct Preferences: Codable, Equatable, Sendable {
    var launchAtLogin = true
    /// Set once the first light has been added (drives the default for launch at login).
    var setupCompleted = false
    /// Tuya IoT Access ID (not secret) and data center, remembered for "refresh keys".
    var cloudAccessID: String?
    var cloudRegion: TuyaCloudRegion?
}

/// Everything persisted in `config.json`. Contains no secrets.
struct AppConfig: Codable, Equatable, Sendable {
    var lights: [Light] = []
    var selection: LightSelection?
    var favorites = Favorites()
    var lastKnownState: [String: LightState] = [:]
    var preferences = Preferences()
}
