import Foundation
import Security

/// Storage for secrets (local keys, Tuya Access Secret). Implemented by the Keychain; faked in tests.
protocol SecretStore: Sendable {
    func save(_ secret: String, account: String) throws
    func read(account: String) throws -> String?
    func delete(account: String) throws
}

enum SecretAccount {
    static func localKey(_ deviceID: String) -> String { "localkey:\(deviceID)" }
    static func cloudSecret(_ accessID: String) -> String { "tuya-cloud:\(accessID)" }
}

struct KeychainError: Error, Equatable { let status: OSStatus }

/// macOS Keychain generic passwords, available after first unlock so the app works at login.
struct KeychainStore: SecretStore {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.catlight.app") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// In-memory store for tests and previews.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func save(_ secret: String, account: String) throws { lock.withLock { items[account] = secret } }
    func read(account: String) throws -> String? { lock.withLock { items[account] } }
    func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
    var accounts: Set<String> { lock.withLock { Set(items.keys) } }
}
