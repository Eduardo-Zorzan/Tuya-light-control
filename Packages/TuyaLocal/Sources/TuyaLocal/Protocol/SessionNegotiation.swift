import CryptoKit
import Foundation

/// Session-key negotiation for protocols 3.4 and 3.5 (commands 3 → 4 → 5).
///
/// 1. Client sends `localNonce` (cmd 3), framed with the *local key*.
/// 2. Device replies (cmd 4) with `remoteNonce ‖ HMAC-SHA256(localKey, localNonce)`.
/// 3. Client verifies, replies (cmd 5) with `HMAC-SHA256(localKey, remoteNonce)`.
/// 4. Both derive the session key from `localNonce ⊕ remoteNonce` encrypted under the local key.
public struct SessionNegotiation: Sendable {
    public let version: TuyaVersion
    public let localKey: Data
    public let localNonce: Data

    public init(version: TuyaVersion, localKey: Data, localNonce: Data = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })) {
        precondition(version != .v33, "3.3 has no session negotiation")
        precondition(localNonce.count == 16, "nonce must be 16 bytes")
        self.version = version
        self.localKey = localKey
        self.localNonce = localNonce
    }

    /// Payload of the cmd-3 frame.
    public var step1Payload: Data { localNonce }

    /// Validates the device's cmd-4 payload and returns the remote nonce and the cmd-5 payload.
    /// Throws `.invalidKey` when the HMAC does not match (wrong local key).
    public func processStep2(_ payload: Data) throws -> (remoteNonce: Data, step3Payload: Data) {
        guard payload.count >= 48 else { throw TuyaError.protocol("short negotiation reply") }
        let remoteNonce = Data(payload.prefix(16))
        let theirMAC = Data(payload[payload.startIndex + 16..<payload.startIndex + 48])
        let expected = Data(HMAC<SHA256>.authenticationCode(for: localNonce, using: SymmetricKey(data: localKey)))
        guard constantTimeEqual(expected, theirMAC) else { throw TuyaError.invalidKey }
        let step3 = Data(HMAC<SHA256>.authenticationCode(for: remoteNonce, using: SymmetricKey(data: localKey)))
        return (remoteNonce, step3)
    }

    /// Derives the 16-byte session key.
    public func sessionKey(remoteNonce: Data) throws -> Data {
        let xored = Data(zip(localNonce, remoteNonce).map { $0 ^ $1 })
        switch version {
        case .v34:
            return try AESECB.encrypt(xored, key: localKey, pad: false)
        case .v35:
            let sealed = try AES.GCM.seal(
                xored, using: SymmetricKey(data: localKey),
                nonce: AES.GCM.Nonce(data: localNonce.prefix(12)))
            return Data(sealed.ciphertext)
        case .v33:
            throw TuyaError.protocol("3.3 has no session key")
        }
    }
}
