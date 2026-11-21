import Foundation

/// Tuya local protocol versions supported by this package.
public enum TuyaVersion: String, Sendable, CaseIterable, Codable, Hashable {
    case v33 = "3.3"
    case v34 = "3.4"
    case v35 = "3.5"

    /// The 15-byte version header: `"3.x"` followed by 12 zero bytes.
    var headerBytes: Data {
        Data(rawValue.utf8) + Data(repeating: 0, count: 12)
    }

    /// Order tried by auto-detection when no version is known.
    public static let detectionOrder: [TuyaVersion] = [.v35, .v34, .v33]
}

/// Command words of the Tuya local protocol.
public enum TuyaCommand {
    public static let sessKeyNegStart: UInt32 = 0x03
    public static let sessKeyNegResp: UInt32 = 0x04
    public static let sessKeyNegFinish: UInt32 = 0x05
    public static let control: UInt32 = 0x07
    public static let status: UInt32 = 0x08
    public static let heartBeat: UInt32 = 0x09
    public static let dpQuery: UInt32 = 0x0A
    public static let controlNew: UInt32 = 0x0D
    public static let dpQueryNew: UInt32 = 0x10
    public static let updateDPs: UInt32 = 0x12
    public static let reqDevInfo: UInt32 = 0x25

    /// Commands whose payload does not carry the `"3.x"` version header.
    static let noVersionHeader: Set<UInt32> = [
        dpQuery, dpQueryNew, updateDPs, heartBeat,
        sessKeyNegStart, sessKeyNegResp, sessKeyNegFinish, 0x40,
    ]
}

/// A datapoint value as it appears in Tuya JSON payloads.
public enum DPValue: Sendable, Equatable, Hashable {
    case bool(Bool)
    case int(Int)
    case string(String)

    var jsonObject: Any {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i
        case .string(let s): return s
        }
    }

    init?(json: Any) {
        // NSNumber bridging: distinguish Bool from Int via CFBoolean identity.
        if let n = json as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .int(n.intValue)
            }
        } else if let s = json as? String {
            self = .string(s)
        } else {
            return nil
        }
    }

    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var intValue: Int? { if case .int(let i) = self { i } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Datapoint id → value map (the `dps` object of Tuya payloads).
public typealias DPMap = [Int: DPValue]

/// Typed errors surfaced by the protocol and client layers.
public enum TuyaError: Error, Sendable, Equatable {
    /// The operation did not complete in time.
    case timeout
    /// The local key is wrong (decrypt/HMAC failed during negotiation or on a reply).
    case invalidKey
    /// TCP connection refused (often: another client already holds the single local slot).
    case connectionRefused
    /// macOS Local Network permission is denied.
    case localNetworkDenied
    /// Malformed frame, unexpected command, or other protocol violation.
    case `protocol`(String)
    /// The connection was closed by the peer or locally.
    case connectionClosed
}
