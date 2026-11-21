import Foundation

/// Reads/writes `config.json` (no secrets) with atomic writes; a corrupt file is set aside and replaced by defaults.
struct ConfigStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    /// `Application Support/<bundle id>/config.json` (inside the sandbox container).
    static func standard(bundleID: String = Bundle.main.bundleIdentifier ?? "com.catlight.app") throws -> ConfigStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ConfigStore(fileURL: base.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("config.json"))
    }

    /// Loads the config. Missing → defaults. Corrupt → the bad file is renamed `config.corrupt-<time>.json` and defaults returned.
    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("config.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return AppConfig()
        }
    }

    func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }
}
