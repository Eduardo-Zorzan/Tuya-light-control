import CryptoKit
import Foundation
import Network

@testable import TuyaLocal

/// A tiny in-process Tuya device (NWListener on loopback) speaking 3.3 / 3.4 / 3.5,
/// with knobs for injecting the failures the connection layer must survive.
final class FakeTuyaDevice: @unchecked Sendable {
    struct Behavior: Sendable {
        var replyHeartbeat = true
        var replyQuery = true
        var ackControl = true
        var pushStatusOnControl = true
        var applyControl = true
        var respondToNegotiation = true
        /// The first N CONTROL frames are received (and recorded) but silently ignored: no ack, no effect.
        var swallowControls = 0
    }

    let version: TuyaVersion
    let localKey: Data
    private let queue = DispatchQueue(label: "fake.device")
    private let lock = NSLock()
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var _behavior = Behavior()
    private var _dps: DPMap
    private var _controls: [DPMap] = []
    private var _heartbeats = 0
    private var _connectionsAccepted = 0
    private var _ready = 0
    private(set) var port: UInt16 = 0

    private final class Conn: @unchecked Sendable {
        let nw: NWConnection
        var buffer = FrameBuffer()
        var codec: TuyaCodec
        var localNonce = Data()
        var remoteNonce = Data((0..<16).map { UInt8(100 + $0) })
        var ready = false
        init(nw: NWConnection, codec: TuyaCodec) { self.nw = nw; self.codec = codec }
    }

    init(version: TuyaVersion, localKey: String = "0123456789abcdef", dps: DPMap = FakeTuyaDevice.defaultDPs) {
        self.version = version
        self.localKey = Data(localKey.utf8)
        self._dps = dps
    }

    static let defaultDPs: DPMap = [
        20: .bool(true), 21: .string("colour"), 22: .int(500), 23: .int(300), 24: .string("003d03e803e8"),
    ]

    // MARK: Observation / control from tests

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }
    var dps: DPMap { lock.withLock { _dps } }
    var controls: [DPMap] { lock.withLock { _controls } }
    var heartbeats: Int { lock.withLock { _heartbeats } }
    var connectionsAccepted: Int { lock.withLock { _connectionsAccepted } }
    /// Connections that finished negotiation (or need none).
    var readyConnections: Int { lock.withLock { _ready } }
    var openConnections: Int { lock.withLock { conns.count } }

    func start() async throws {
        try await listen(on: nil)
    }

    private func listen(on fixedPort: UInt16?) async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try fixedPort.map { try NWListener(using: params, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port!.rawValue
    }

    /// Simulates the light losing power: connections drop and new ones are refused.
    func goOffline() {
        listener?.cancel()
        listener = nil
        dropConnections()
    }

    /// Simulates the light coming back on the same address/port.
    func goOnline() async throws {
        guard listener == nil else { return }
        // The cancelled listener releases the port asynchronously.
        for _ in 0..<50 {
            do { try await listen(on: port); return } catch { try await Task.sleep(for: .milliseconds(20)) }
        }
        try await listen(on: port)
    }

    func stop() {
        listener?.cancel()
        dropConnections()
    }

    func dropConnections() {
        let all = lock.withLock { Array(conns.values) }
        for c in all { c.nw.cancel() }
    }

    /// Pushes a STATUS frame to every connected (negotiated) client.
    func push(_ dps: DPMap) {
        lock.withLock { for (k, v) in dps { _dps[k] = v } }
        let all = lock.withLock { conns.values.filter { $0.ready } }
        queue.async {
            for c in all { self.sendStatus(dps, on: c) }
        }
    }

    // MARK: Connection handling

    private func accept(_ nw: NWConnection) {
        let conn = Conn(nw: nw, codec: TuyaCodec(version: version, key: localKey))
        lock.withLock {
            conns[ObjectIdentifier(conn)] = conn
            _connectionsAccepted += 1
        }
        if version == .v33 { markReady(conn) }
        nw.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            if case .failed = state { self.remove(conn) }
            if case .cancelled = state { self.remove(conn) }
        }
        nw.start(queue: queue)
        receive(conn)
    }

    private func markReady(_ conn: Conn) {
        lock.withLock { if !conn.ready { conn.ready = true; _ready += 1 } }
    }

    private func remove(_ conn: Conn) {
        lock.withLock { if conns.removeValue(forKey: ObjectIdentifier(conn)) != nil, conn.ready { _ready -= 1 } }
    }

    private func receive(_ conn: Conn) {
        conn.nw.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                conn.buffer.append(data)
                do {
                    while let frame = try conn.buffer.nextFrame() { self.handle(frame, on: conn) }
                } catch {
                    conn.nw.cancel()
                    return
                }
            }
            if error != nil || isComplete { conn.nw.cancel(); return }
            self.receive(conn)
        }
    }

    private func handle(_ raw: Data, on conn: Conn) {
        let frame: TuyaFrame
        // A real device only understands its own frame family (0x6699 for 3.5, 0x55AA otherwise).
        let is6699 = raw.readBE32(at: 0) == 0x0000_6699
        guard is6699 == (version == .v35) else { conn.nw.cancel(); return }
        do { frame = try conn.codec.decode(raw, fromDevice: false) } catch {
            // A real device just stops talking to a client that uses the wrong version/key.
            conn.nw.cancel()
            return
        }
        let b = behavior
        switch frame.command {
        case TuyaCommand.sessKeyNegStart:
            guard b.respondToNegotiation, version != .v33 else { return }
            conn.localNonce = frame.payload.prefix(16)
            let mac = Data(HMAC<SHA256>.authenticationCode(for: conn.localNonce, using: SymmetricKey(data: localKey)))
            reply(conn, command: TuyaCommand.sessKeyNegResp, seq: frame.seq, payload: conn.remoteNonce + mac)
        case TuyaCommand.sessKeyNegFinish:
            let expected = Data(HMAC<SHA256>.authenticationCode(for: conn.remoteNonce, using: SymmetricKey(data: localKey)))
            guard expected == frame.payload.prefix(32) else { conn.nw.cancel(); return }
            let neg = SessionNegotiation(version: version, localKey: localKey, localNonce: conn.localNonce)
            if let key = try? neg.sessionKey(remoteNonce: conn.remoteNonce) { conn.codec = conn.codec.with(key: key) }
            markReady(conn)
        case TuyaCommand.heartBeat:
            lock.withLock { _heartbeats += 1 }
            if b.replyHeartbeat { reply(conn, command: frame.command, seq: frame.seq, payload: Data()) }
        case TuyaCommand.dpQuery, TuyaCommand.dpQueryNew:
            if b.replyQuery { reply(conn, command: frame.command, seq: frame.seq, payload: queryResponse()) }
        case TuyaCommand.control, TuyaCommand.controlNew:
            let set = (try? TuyaPayloads.parseDPs(frame.payload)) ?? [:]
            let swallow = lock.withLock { () -> Bool in
                _controls.append(set)
                if _behavior.swallowControls > 0 { _behavior.swallowControls -= 1; return true }
                return false
            }
            if swallow { return }
            if b.applyControl { lock.withLock { for (k, v) in set { _dps[k] = v } } }
            if b.ackControl { reply(conn, command: frame.command, seq: frame.seq, payload: Data()) }
            if b.pushStatusOnControl && b.applyControl { sendStatus(set, on: conn) }
        default:
            break
        }
    }

    private func reply(_ conn: Conn, command: UInt32, seq: UInt32, payload: Data) {
        guard let bytes = try? conn.codec.encodeResponse(command: command, seq: seq, payload: payload) else { return }
        conn.nw.send(content: bytes, completion: .contentProcessed { _ in })
    }

    private func sendStatus(_ dps: DPMap, on conn: Conn) {
        let obj = Dictionary(uniqueKeysWithValues: dps.map { (String($0.key), $0.value.jsonObject) })
        let json: [String: Any] = version == .v33 ? ["dps": obj] : ["protocol": 4, "t": 1_700_000_000, "data": ["dps": obj]]
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        guard let bytes = try? conn.codec.encodeResponse(command: TuyaCommand.status, seq: 0, payload: payload, withVersionHeader: true)
        else { return }
        conn.nw.send(content: bytes, completion: .contentProcessed { _ in })
    }

    private func queryResponse() -> Data {
        let obj = Dictionary(uniqueKeysWithValues: dps.map { (String($0.key), $0.value.jsonObject) })
        let json: [String: Any] = version == .v33 ? ["devId": "fake", "dps": obj] : ["data": ["dps": obj]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.withLock {
            if done { return false }; done = true; return true
        }
    }
}

/// Polls until `condition` holds (real time), failing the test run via timeout instead of hanging.
func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// First value of `stream` or `nil` after `timeout`.
func firstValue<S: AsyncSequence & Sendable>(of stream: S, timeout: Duration = .seconds(3)) async -> S.Element? where S.Element: Sendable {
    await withTaskGroup(of: S.Element?.self) { group in
        group.addTask { try? await stream.first(where: { _ in true }) }
        group.addTask {
            try? await Task.sleep(for: timeout); return nil
        }
        let r = await group.next() ?? nil
        group.cancelAll()
        return r
    }
}
