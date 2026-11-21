import CryptoKit
import Foundation
import TuyaLocal

/// Tuya IoT Platform data centers (a Brazilian account is normally "Western America").
enum TuyaCloudRegion: String, CaseIterable, Codable, Identifiable, Sendable {
    case westernAmerica, easternAmerica, centralEurope, westernEurope, india, china

    var id: String { rawValue }

    var host: String {
        switch self {
        case .westernAmerica: return "openapi.tuyaus.com"
        case .easternAmerica: return "openapi-ueaz.tuyaus.com"
        case .centralEurope: return "openapi.tuyaeu.com"
        case .westernEurope: return "openapi-weaz.tuyaeu.com"
        case .india: return "openapi.tuyain.com"
        case .china: return "openapi.tuyacn.com"
        }
    }

    var title: String {
        switch self {
        case .westernAmerica: return "América Ocidental (EUA)"
        case .easternAmerica: return "América Oriental (EUA)"
        case .centralEurope: return "Europa Central"
        case .westernEurope: return "Europa Ocidental"
        case .india: return "Índia"
        case .china: return "China"
        }
    }
}

struct CloudCredentials: Equatable, Sendable {
    var accessID: String
    var accessSecret: String
    var region: TuyaCloudRegion
}

struct CloudDevice: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var localKey: String
    var productID: String?
    var category: String?
    var ip: String?
    var online: Bool

    /// Tuya light categories: dj (light), dd (strip), xdd (ceiling), fwd (ambient), dc (string), tgq (dimmer light).
    var isLight: Bool { ["dj", "dd", "xdd", "fwd", "dc", "tgq"].contains(category ?? "") }
}

struct CloudDPSpec: Equatable, Sendable {
    var code: String
    var type: String?
}

enum TuyaCloudError: Error, Equatable, LocalizedError {
    /// Error reported by Tuya (e.g. 1004 "sign invalid"); shown to the user as is.
    case api(code: Int, message: String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): return "Tuya: \(message) (\(code))"
        case .network(let m): return "Sem conexão com a Tuya: \(m)"
        case .badResponse: return "Resposta inesperada da Tuya."
        }
    }
}

/// Minimal Tuya OpenAPI client used only for importing lights and refreshing their local keys.
final class TuyaCloudClient: @unchecked Sendable {
    private let credentials: CloudCredentials
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var token: (value: String, expires: Date)?

    init(credentials: CloudCredentials, session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.session = session
        self.now = now
    }

    // MARK: Signing

    /// `HMAC-SHA256(secret, clientID + token + t + METHOD\nsha256(body)\n<signed headers>\npath?query)`, uppercase hex.
    static func signature(
        secret: String, clientID: String, token: String?, timestamp: Int64, method: String, body: Data, pathAndQuery: String
    ) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let payload = clientID + (token ?? "") + String(timestamp) + "\(method)\n\(bodyHash)\n\n\(pathAndQuery)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Public API

    /// Lists the devices of the linked app account, with local keys.
    func fetchDevices() async throws -> [CloudDevice] {
        var devices: [CloudDevice] = []
        var lastRowKey = ""
        for _ in 0..<50 {  // paging guard
            let result = try await get("/v1.0/iot-01/associated-users/devices", query: [("last_row_key", lastRowKey), ("size", "100")])
            let page = (result["devices"] as? [[String: Any]]) ?? []
            devices += page.compactMap(Self.parseDevice)
            guard (result["has_more"] as? Bool) == true, let next = result["last_row_key"] as? String, !next.isEmpty else { break }
            lastRowKey = next
        }
        return devices
    }

    /// Re-fetches the local keys of already registered lights ("refresh keys").
    func refreshKeys(for deviceIDs: [String]) async throws -> [String: String] {
        let wanted = Set(deviceIDs)
        let devices = try await fetchDevices()
        return Dictionary(
            uniqueKeysWithValues: devices.filter { wanted.contains($0.id) && !$0.localKey.isEmpty }.map { ($0.id, $0.localKey) })
    }

    /// Datapoint codes of a device, used to tell the v2 profile from the legacy one.
    func specifications(deviceID: String) async throws -> [CloudDPSpec] {
        let result = try await get("/v1.0/devices/\(deviceID)/specifications", query: [])
        let lists = ((result["functions"] as? [[String: Any]]) ?? []) + ((result["status"] as? [[String: Any]]) ?? [])
        return lists.compactMap { item in (item["code"] as? String).map { CloudDPSpec(code: $0, type: item["type"] as? String) } }
    }

    static func profile(from specs: [CloudDPSpec]) -> DPProfile? {
        let codes = Set(specs.map(\.code))
        if codes.contains("colour_data_v2") || codes.contains("bright_value_v2") || codes.contains("switch_led") { return .v2 }
        if codes.contains("colour_data") || codes.contains("bright_value") || codes.contains("switch") { return .legacy }
        return nil
    }

    // MARK: Plumbing

    static func parseDevice(_ d: [String: Any]) -> CloudDevice? {
        guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
        return CloudDevice(
            id: id, name: name, localKey: (d["local_key"] as? String) ?? "", productID: d["product_id"] as? String,
            category: d["category"] as? String, ip: d["ip"] as? String, online: (d["online"] as? Bool) ?? false)
    }

    private func accessToken() async throws -> String {
        if let cached = lock.withLock({ token }), cached.expires > now().addingTimeInterval(60) { return cached.value }
        let result = try await send(path: "/v1.0/token", query: [("grant_type", "1")], token: nil)
        guard let value = result["access_token"] as? String else { throw TuyaCloudError.badResponse }
        let lifetime = (result["expire_time"] as? Double) ?? 7200
        lock.withLock { token = (value, now().addingTimeInterval(lifetime)) }
        return value
    }

    private func get(_ path: String, query: [(String, String)]) async throws -> [String: Any] {
        let token = try await accessToken()
        return try await send(path: path, query: query, token: token)
    }

    private func send(path: String, query: [(String, String)], token: String?) async throws -> [String: Any] {
        // Tuya requires the query parameters sorted by key, and signs the un-encoded string.
        let sorted = query.sorted { $0.0 < $1.0 }
        let queryString = sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let pathAndQuery = queryString.isEmpty ? path : "\(path)?\(queryString)"
        guard let url = URL(string: "https://\(credentials.region.host)\(pathAndQuery)") else { throw TuyaCloudError.badResponse }

        let t = Int64(now().timeIntervalSince1970 * 1000)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(credentials.accessID, forHTTPHeaderField: "client_id")
        request.setValue(t.description, forHTTPHeaderField: "t")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if let token { request.setValue(token, forHTTPHeaderField: "access_token") }
        request.setValue(
            Self.signature(
                secret: credentials.accessSecret, clientID: credentials.accessID, token: token, timestamp: t, method: "GET",
                body: Data(), pathAndQuery: pathAndQuery),
            forHTTPHeaderField: "sign")

        let data: Data
        do { (data, _) = try await session.data(for: request) } catch { throw TuyaCloudError.network(error.localizedDescription) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TuyaCloudError.badResponse }
        if (object["success"] as? Bool) == true, let result = object["result"] as? [String: Any] { return result }
        if (object["success"] as? Bool) == true { return [:] }
        throw TuyaCloudError.api(code: (object["code"] as? Int) ?? -1, message: (object["msg"] as? String) ?? "erro desconhecido")
    }
}
