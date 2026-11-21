import Foundation
import Testing

@testable import TuyaLocal

private typealias V33 = TinytuyaVectors.V33
private typealias V34 = TinytuyaVectors.V34
private typealias V35 = TinytuyaVectors.V35
private let fixedIV = Data("0123456789ab".utf8)

@Suite("3.3 framing")
struct Frame33Tests {
    let codec = TuyaCodec(version: .v33, key: testKey)

    @Test func encodeQueryMatchesTinytuya() throws {
        let frame = try codec.encode(command: TuyaCommand.dpQuery, seq: 1, payload: Data(V33.queryPayload.utf8))
        #expect(frame.hex == V33.queryFrame)
    }

    @Test func encodeControlHasUnencryptedVersionHeader() throws {
        let frame = try codec.encode(command: TuyaCommand.control, seq: 2, payload: Data(V33.controlPayload.utf8))
        #expect(frame.hex == V33.controlFrame)
        #expect(frame.hex.contains("332e33" + String(repeating: "00", count: 12)))
    }

    @Test func encodeHeartbeatMatchesTinytuya() throws {
        let frame = try codec.encode(command: TuyaCommand.heartBeat, seq: 3, payload: Data(V33.heartbeatPayload.utf8))
        #expect(frame.hex == V33.heartbeatFrame)
    }

    @Test func decodeDeviceResponse() throws {
        let f = try codec.decode(Data(hex: V33.responseFrame))
        #expect(f.seq == 7)
        #expect(f.command == TuyaCommand.dpQuery)
        #expect(f.retcode == 0)
        #expect(String(decoding: f.payload, as: UTF8.self) == V33.responsePayload)
    }

    @Test func decodeStatusPushStripsVersionHeader() throws {
        let f = try codec.decode(Data(hex: V33.statusFrame))
        #expect(f.command == TuyaCommand.status)
        #expect(String(decoding: f.payload, as: UTF8.self) == V33.statusPayload)
    }

    @Test func clientFrameRoundTripsAsServer() throws {
        let frame = try codec.encode(command: TuyaCommand.control, seq: 9, payload: Data(V33.controlPayload.utf8))
        let f = try codec.decode(frame, fromDevice: false)
        #expect(f.seq == 9)
        #expect(String(decoding: f.payload, as: UTF8.self) == V33.controlPayload)
    }

    @Test func corruptedCRCIsRejected() throws {
        var bytes = Data(hex: V33.responseFrame)
        bytes[bytes.count - 6] ^= 0xFF
        #expect(throws: TuyaError.invalidKey) { try codec.decode(bytes) }
    }

    @Test func wrongKeyNeverYieldsThePlaintext() throws {
        let other = TuyaCodec(version: .v33, key: Data("fedcba9876543210".utf8))
        // CRC is key-independent in 3.3: a wrong key either fails PKCS7 or yields garbage.
        // (Garbage is rejected one layer up, where the JSON payload is parsed -> invalidKey.)
        if let f = try? other.decode(Data(hex: V33.responseFrame)) {
            #expect(String(decoding: f.payload, as: UTF8.self) != V33.responsePayload)
        }
    }

    @Test func frameLengthSupportsReassembly() throws {
        let bytes = Data(hex: V33.responseFrame)
        #expect(try TuyaCodec.frameLength(in: bytes.prefix(10)) == nil)
        #expect(try TuyaCodec.frameLength(in: bytes) == bytes.count)
        #expect(try TuyaCodec.frameLength(in: bytes + bytes) == bytes.count)
        #expect(throws: TuyaError.self) { try TuyaCodec.frameLength(in: Data(hex: "deadbeef")) }
    }
}

@Suite("3.4 negotiation and frames")
struct Frame34Tests {
    let local = TuyaCodec(version: .v34, key: testKey)
    let localNonce = Data(hex: V34.localNonce)
    let remoteNonce = Data(hex: V34.remoteNonce)

    @Test func step1FrameMatchesTinytuya() throws {
        let neg = SessionNegotiation(version: .v34, localKey: testKey, localNonce: localNonce)
        let frame = try local.encode(command: TuyaCommand.sessKeyNegStart, seq: 1, payload: neg.step1Payload)
        #expect(frame.hex == V34.step1Frame)
    }

    @Test func fullNegotiationMatchesTinytuyaSessionKey() throws {
        let neg = SessionNegotiation(version: .v34, localKey: testKey, localNonce: localNonce)
        let reply = try local.decode(Data(hex: V34.step2Frame))
        #expect(reply.command == TuyaCommand.sessKeyNegResp)
        let (remote, step3) = try neg.processStep2(reply.payload)
        #expect(remote == remoteNonce)
        let step3Frame = try local.encode(command: TuyaCommand.sessKeyNegFinish, seq: 2, payload: step3)
        #expect(step3Frame.hex == V34.step3Frame)
        #expect(try neg.sessionKey(remoteNonce: remote).hex == V34.sessionKey)
    }

    @Test func wrongLocalKeyIsRejected() throws {
        // A device holding a different key signs with it, so frame integrity already fails.
        let wrong = TuyaCodec(version: .v34, key: Data("fedcba9876543210".utf8))
        #expect(throws: TuyaError.invalidKey) { try wrong.decode(Data(hex: V34.step2Frame)) }
        // Even if the frame decoded, a wrong key must fail the nonce HMAC check.
        let neg = SessionNegotiation(version: .v34, localKey: Data("fedcba9876543210".utf8), localNonce: localNonce)
        let payload = remoteNonce + Data(repeating: 0xAB, count: 32)
        #expect(throws: TuyaError.invalidKey) { try neg.processStep2(payload) }
    }

    @Test func sessionFramesMatchTinytuya() throws {
        let session = local.with(key: Data(hex: V34.sessionKey))
        let control = try session.encode(command: TuyaCommand.controlNew, seq: 3, payload: Data(V34.controlPayload.utf8))
        #expect(control.hex == V34.controlFrame)
        let query = try session.encode(command: TuyaCommand.dpQueryNew, seq: 4, payload: Data("{}".utf8))
        #expect(query.hex == V34.queryFrame)
    }

    @Test func statusPushDecodesAndStripsHeader() throws {
        let session = local.with(key: Data(hex: V34.sessionKey))
        let f = try session.decode(Data(hex: V34.statusFrame))
        #expect(f.command == TuyaCommand.status)
        #expect(String(decoding: f.payload, as: UTF8.self) == #"{"protocol":4,"t":1700000000,"data":{"dps":{"20":false}}}"#)
    }

    @Test func tamperedHMACIsRejected() throws {
        let session = local.with(key: Data(hex: V34.sessionKey))
        var bytes = Data(hex: V34.statusFrame)
        bytes[20] ^= 0x01
        #expect(throws: TuyaError.invalidKey) { try session.decode(bytes) }
    }
}

@Suite("3.5 framing")
struct Frame35Tests {
    let local = TuyaCodec(version: .v35, key: testKey, ivProvider: { fixedIV })
    let localNonce = Data(hex: V35.localNonce)
    let remoteNonce = Data(hex: V35.remoteNonce)

    @Test func negotiationFramesAndSessionKeyMatchTinytuya() throws {
        let neg = SessionNegotiation(version: .v35, localKey: testKey, localNonce: localNonce)
        #expect(try local.encode(command: TuyaCommand.sessKeyNegStart, seq: 1, payload: neg.step1Payload).hex == V35.step1Frame)
        let reply = try local.decode(Data(hex: V35.step2Frame))
        #expect(reply.command == TuyaCommand.sessKeyNegResp)
        let (remote, step3) = try neg.processStep2(reply.payload)
        #expect(remote == remoteNonce)
        #expect(try local.encode(command: TuyaCommand.sessKeyNegFinish, seq: 2, payload: step3).hex == V35.step3Frame)
        #expect(try neg.sessionKey(remoteNonce: remote).hex == V35.sessionKey)
    }

    @Test func sessionFramesMatchTinytuya() throws {
        let session = local.with(key: Data(hex: V35.sessionKey))
        #expect(try session.encode(command: TuyaCommand.controlNew, seq: 3, payload: Data(V35.controlPayload.utf8)).hex == V35.controlFrame)
        #expect(try session.encode(command: TuyaCommand.dpQueryNew, seq: 4, payload: Data("{}".utf8)).hex == V35.queryFrame)
    }

    @Test func statusPushDecodes() throws {
        let session = local.with(key: Data(hex: V35.sessionKey))
        let f = try session.decode(Data(hex: V35.statusFrame))
        #expect(f.command == TuyaCommand.status)
        #expect(f.retcode == 0)
        #expect(String(decoding: f.payload, as: UTF8.self) == #"{"protocol":4,"t":1700000000,"data":{"dps":{"20":false}}}"#)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let codec = TuyaCodec(version: .v35, key: Data(hex: V35.sessionKey))  // random IV
        let frame = try codec.encode(command: TuyaCommand.controlNew, seq: 77, payload: Data(V35.controlPayload.utf8))
        let f = try codec.decode(frame, fromDevice: false)
        #expect(f.seq == 77)
        #expect(String(decoding: f.payload, as: UTF8.self) == V35.controlPayload)
    }

    @Test func tagMismatchIsRejected() throws {
        let session = local.with(key: Data(hex: V35.sessionKey))
        var bytes = Data(hex: V35.statusFrame)
        bytes[bytes.count - 6] ^= 0x01  // inside the GCM tag
        #expect(throws: TuyaError.invalidKey) { try session.decode(bytes) }
    }

    @Test func tamperedHeaderFailsAuthentication() throws {
        let session = local.with(key: Data(hex: V35.sessionKey))
        var bytes = Data(hex: V35.statusFrame)
        bytes[9] ^= 0x01  // sequence number is authenticated as AAD
        #expect(throws: TuyaError.invalidKey) { try session.decode(bytes) }
    }
}
