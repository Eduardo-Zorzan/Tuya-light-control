import CryptoKit
import Foundation

/// A device announced on the LAN by its UDP discovery broadcast.
public struct DiscoveredDevice: Sendable, Equatable, Hashable {
    public var deviceID: String
    public var ip: String
    public var version: TuyaVersion?
    public var productKey: String?

    public init(deviceID: String, ip: String, version: TuyaVersion? = nil, productKey: String? = nil) {
        self.deviceID = deviceID
        self.ip = ip
        self.version = version
        self.productKey = productKey
    }
}

/// Decodes Tuya discovery datagrams (ports 6666 / 6667 / 7000).
public enum DiscoveryDecoder {
    /// Well-known key protecting discovery broadcasts: `MD5("yGAdlopoPVldABfn")`.
    static let udpKey = Data(Insecure.MD5.hash(data: Data("yGAdlopoPVldABfn".utf8)))

    /// Returns the announced device, or `nil` for anything that is not a valid broadcast.
    /// `senderIP` is used when the payload does not carry an `ip` field.
    public static func decode(_ datagram: Data, senderIP: String? = nil) -> DiscoveredDevice? {
        guard let json = decodeJSON(datagram),
            let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        else { return nil }
        guard let id = (object["gwId"] as? String) ?? (object["id"] as? String), !id.isEmpty else { return nil }
        guard let ip = (object["ip"] as? String) ?? senderIP, !ip.isEmpty else { return nil }
        let version = (object["version"] as? String).flatMap(TuyaVersion.init(rawValue:))
        return DiscoveredDevice(deviceID: id, ip: ip, version: version, productKey: object["productKey"] as? String)
    }

    private static func decodeJSON(_ datagram: Data) -> Data? {
        let data = Data(datagram)
        guard data.count >= 4 else { return nil }
        switch data.readBE32(at: 0) {
        case TuyaCodec.prefix55AA:
            guard let total = try? TuyaCodec.frameLength(in: data), data.count >= total, total >= 16 + 4 + 8 else { return nil }
            let frame = data.prefix(total)
            let crcStart = total - 8
            guard TuyaCodec.crc32(frame.prefix(crcStart)) == Data(frame).readBE32(at: crcStart) else { return nil }
            let payload = Data(frame[(16 + 4)..<crcStart])  // skip the 4-byte return code
            if payload.first == UInt8(ascii: "{") { return payload }
            return try? AESECB.decrypt(payload, key: udpKey)
        case TuyaCodec.prefix6699:
            let codec = TuyaCodec(version: .v35, key: udpKey)
            guard let total = try? TuyaCodec.frameLength(in: data), data.count >= total,
                let frame = try? codec.decode(data.prefix(total))
            else { return nil }
            // Some app-originated broadcasts pad with NULs.
            return Data(frame.payload.reversed().drop(while: { $0 == 0 }).reversed())
        default:
            // Raw ECB-encrypted JSON (older firmware).
            return try? AESECB.decrypt(data, key: udpKey)
        }
    }
}
