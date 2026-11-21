import CryptoKit
import Foundation
import zlib

/// A decoded protocol frame with its payload already decrypted and the `"3.x"`
/// version header (if any) stripped.
public struct TuyaFrame: Sendable, Equatable {
    public var seq: UInt32
    public var command: UInt32
    /// Return code present on device→client frames.
    public var retcode: UInt32?
    public var payload: Data

    public init(seq: UInt32, command: UInt32, retcode: UInt32? = nil, payload: Data) {
        self.seq = seq
        self.command = command
        self.retcode = retcode
        self.payload = payload
    }
}

/// Encodes and decodes wire frames for one protocol version under one key
/// (the local key before negotiation, the session key after it).
public struct TuyaCodec: Sendable {
    public let version: TuyaVersion
    public let key: Data
    /// GCM nonce source for 3.5 encoding; overridable so tests can use fixed vectors.
    let ivProvider: @Sendable () -> Data

    static let prefix55AA: UInt32 = 0x0000_55AA
    static let suffix55AA: UInt32 = 0x0000_AA55
    static let prefix6699: UInt32 = 0x0000_6699
    static let suffix6699: UInt32 = 0x0000_9966
    static let header55AALength = 16
    static let header6699Length = 18
    /// Sanity bound against corrupt/desynced streams.
    static let maxPayloadLength = 0x1000

    public init(version: TuyaVersion, key: Data) {
        self.init(version: version, key: key, ivProvider: { Data(AES.GCM.Nonce()) })
    }

    init(version: TuyaVersion, key: Data, ivProvider: @escaping @Sendable () -> Data) {
        self.version = version
        self.key = key
        self.ivProvider = ivProvider
    }

    /// Same version, different key (used after session negotiation).
    public func with(key: Data) -> TuyaCodec {
        TuyaCodec(version: version, key: key, ivProvider: ivProvider)
    }

    // MARK: Encode

    /// Builds a complete client→device frame.
    public func encode(command: UInt32, seq: UInt32, payload: Data) throws -> Data {
        let needsHeader = !TuyaCommand.noVersionHeader.contains(command)
        switch version {
        case .v33:
            var body = try AESECB.encrypt(payload, key: key)
            if needsHeader { body = version.headerBytes + body }
            return frame55AA(seq: seq, command: command, body: body, hmacKey: nil)
        case .v34:
            let plain = needsHeader ? version.headerBytes + payload : payload
            let body = try AESECB.encrypt(plain, key: key)
            return frame55AA(seq: seq, command: command, body: body, hmacKey: key)
        case .v35:
            let plain = needsHeader ? version.headerBytes + payload : payload
            return try frame6699(seq: seq, command: command, plain: plain, retcode: nil)
        }
    }

    /// Builds a device→client frame (used by tests and the fake device server).
    public func encodeResponse(command: UInt32, seq: UInt32, retcode: UInt32 = 0, payload: Data, withVersionHeader: Bool = false) throws
        -> Data
    {
        let rc = withUnsafeBytes(of: retcode.bigEndian) { Data($0) }
        switch version {
        case .v33:
            var body = payload.isEmpty ? Data() : try AESECB.encrypt(payload, key: key)
            if withVersionHeader { body = version.headerBytes + body }
            return frame55AA(seq: seq, command: command, body: rc + body, hmacKey: nil)
        case .v34:
            let plain = withVersionHeader ? version.headerBytes + payload : payload
            let body = plain.isEmpty ? Data() : try AESECB.encrypt(plain, key: key)
            return frame55AA(seq: seq, command: command, body: rc + body, hmacKey: key)
        case .v35:
            let plain = withVersionHeader ? version.headerBytes + payload : payload
            return try frame6699(seq: seq, command: command, plain: plain, retcode: retcode)
        }
    }

    private func frame55AA(seq: UInt32, command: UInt32, body: Data, hmacKey: Data?) -> Data {
        let endLength = hmacKey == nil ? 8 : 36
        var out = Data()
        out.appendBE(Self.prefix55AA)
        out.appendBE(seq)
        out.appendBE(command)
        out.appendBE(UInt32(body.count + endLength))
        out.append(body)
        if let hmacKey {
            out.append(Data(HMAC<SHA256>.authenticationCode(for: out, using: SymmetricKey(data: hmacKey))))
        } else {
            out.appendBE(Self.crc32(out))
        }
        out.appendBE(Self.suffix55AA)
        return out
    }

    private func frame6699(seq: UInt32, command: UInt32, plain: Data, retcode: UInt32?) throws -> Data {
        var raw = Data()
        if let retcode { raw.appendBE(retcode) }
        raw.append(plain)
        let iv = ivProvider()
        precondition(iv.count == 12, "GCM nonce must be 12 bytes")
        var out = Data()
        out.appendBE(Self.prefix6699)
        out.appendBE(UInt16(0))
        out.appendBE(seq)
        out.appendBE(command)
        out.appendBE(UInt32(12 + raw.count + 16))
        let aad = out.suffix(14)
        let sealed = try AES.GCM.seal(
            raw, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
        out.append(iv)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        out.appendBE(Self.suffix6699)
        return out
    }

    // MARK: Decode

    /// Total length in bytes of the frame starting at `data`, or `nil` if the header is not yet complete.
    /// Throws if the prefix is unknown or the declared length is absurd.
    public static func frameLength(in data: Data) throws -> Int? {
        guard data.count >= 4 else { return nil }
        let prefix = data.readBE32(at: 0)
        switch prefix {
        case prefix55AA:
            guard data.count >= header55AALength else { return nil }
            let len = Int(data.readBE32(at: 12))
            guard len <= maxPayloadLength else { throw TuyaError.protocol("frame too large (\(len))") }
            return header55AALength + len
        case prefix6699:
            guard data.count >= header6699Length else { return nil }
            let len = Int(data.readBE32(at: 14))
            guard len <= maxPayloadLength else { throw TuyaError.protocol("frame too large (\(len))") }
            return header6699Length + len + 4
        default:
            throw TuyaError.protocol(String(format: "bad frame prefix %08X", prefix))
        }
    }

    /// Decodes one complete frame. `fromDevice` says whether a return code is expected.
    /// Throws `.invalidKey` when integrity (CRC/HMAC/GCM tag) or decryption fails.
    public func decode(_ frame: Data, fromDevice: Bool = true) throws -> TuyaFrame {
        let frame = Data(frame)  // normalize indices to start at 0
        guard let total = try Self.frameLength(in: frame), frame.count >= total else {
            throw TuyaError.protocol("incomplete frame")
        }
        let prefix = frame.readBE32(at: 0)
        if prefix == Self.prefix55AA { return try decode55AA(frame.prefix(total), fromDevice: fromDevice) }
        return try decode6699(frame.prefix(total), fromDevice: fromDevice)
    }

    private func decode55AA(_ frame: Data, fromDevice: Bool) throws -> TuyaFrame {
        let frame = Data(frame)
        let seq = frame.readBE32(at: 4)
        let command = frame.readBE32(at: 8)
        let hmacMode = version != .v33
        // 3.4 uses HMAC frames after the session key is negotiated and also for the negotiation
        // frames themselves (keyed with the local key), so every 3.4 frame carries an HMAC.
        let endLength = hmacMode ? 36 : 8
        let declared = Int(frame.readBE32(at: 12))
        guard declared >= endLength, frame.count == Self.header55AALength + declared else {
            throw TuyaError.protocol("bad frame length")
        }
        let signedEnd = frame.count - endLength
        let signed = frame.prefix(signedEnd)
        let tag = frame[signedEnd..<(frame.count - 4)]
        let valid: Bool
        if hmacMode {
            let expected = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: key)))
            valid = constantTimeEqual(expected, Data(tag))
        } else {
            valid = Self.crc32(signed) == Data(tag).readBE32(at: 0)
        }
        guard valid else { throw TuyaError.invalidKey }

        var body = Data(frame[Self.header55AALength..<signedEnd])
        var retcode: UInt32?
        if fromDevice {
            guard body.count >= 4 else { throw TuyaError.protocol("missing return code") }
            retcode = body.readBE32(at: 0)
            body = Data(body.dropFirst(4))
        }
        var payload = Data()
        if !body.isEmpty {
            do {
                switch version {
                case .v33:
                    if body.starts(with: Data(version.rawValue.utf8)), body.count >= 15 {
                        body = Data(body.dropFirst(15))
                    }
                    payload = body.isEmpty ? Data() : try AESECB.decrypt(body, key: key)
                case .v34:
                    payload = try AESECB.decrypt(body, key: key)
                    if payload.starts(with: Data(version.rawValue.utf8)), payload.count >= 15 {
                        payload = Data(payload.dropFirst(15))
                    }
                case .v35:
                    throw TuyaError.protocol("3.5 uses 0x6699 frames")
                }
            } catch let e as TuyaError {
                throw e
            } catch {
                throw TuyaError.invalidKey
            }
        }
        return TuyaFrame(seq: seq, command: command, retcode: retcode, payload: payload)
    }

    private func decode6699(_ frame: Data, fromDevice: Bool) throws -> TuyaFrame {
        let frame = Data(frame)
        let seq = frame.readBE32(at: 6)
        let command = frame.readBE32(at: 10)
        let length = Int(frame.readBE32(at: 14))
        guard length >= 12 + 16, frame.count == Self.header6699Length + length + 4 else {
            throw TuyaError.protocol("bad frame length")
        }
        guard frame.readBE32(at: frame.count - 4) == Self.suffix6699 else {
            throw TuyaError.protocol("bad suffix")
        }
        let aad = frame[4..<Self.header6699Length]
        let iv = frame[Self.header6699Length..<(Self.header6699Length + 12)]
        let cipherEnd = Self.header6699Length + length - 16
        let ciphertext = frame[(Self.header6699Length + 12)..<cipherEnd]
        let tag = frame[cipherEnd..<(cipherEnd + 16)]
        var plain: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            plain = Data(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
        } catch {
            throw TuyaError.invalidKey
        }
        var retcode: UInt32?
        if fromDevice, plain.count >= 4 {
            // The retcode is optional on 3.5 pushes: strip it only if what follows looks like a payload.
            let first = plain.first
            let looksPlain = first == UInt8(ascii: "{") || plain.starts(with: Data("3.".utf8))
            if !looksPlain {
                retcode = plain.readBE32(at: 0)
                plain = Data(plain.dropFirst(4))
            }
        }
        if plain.starts(with: Data(version.rawValue.utf8)), plain.count >= 15 {
            plain = Data(plain.dropFirst(15))
        }
        return TuyaFrame(seq: seq, command: command, retcode: retcode, payload: plain)
    }

    // MARK: Helpers

    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf in
            let bytes = buf.bindMemory(to: UInt8.self)
            return UInt32(zlib.crc32(0, bytes.baseAddress, UInt32(bytes.count)))
        }
    }
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
    mutating func appendBE(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) }
    }
    func readBE32(at offset: Int) -> UInt32 {
        let s = startIndex + offset
        return (UInt32(self[s]) << 24) | (UInt32(self[s + 1]) << 16) | (UInt32(self[s + 2]) << 8) | UInt32(self[s + 3])
    }
}
