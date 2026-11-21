import Foundation

/// Async client for one Tuya device over the local protocol (3.3 / 3.4 / 3.5).
///
/// Lifecycle: `connect()` → `queryDPs()` / `setDPs()` / `heartbeat()` → `close()`.
/// Device-pushed `STATUS` frames are delivered on `statusUpdates`.
public actor TuyaClient {
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var deviceID: String
        public var localKey: String
        public var version: TuyaVersion
        public var connectTimeout: Duration
        public var responseTimeout: Duration

        public init(
            host: String, port: UInt16 = 6668, deviceID: String, localKey: String,
            version: TuyaVersion, connectTimeout: Duration = .seconds(3), responseTimeout: Duration = .seconds(5)
        ) {
            self.host = host
            self.port = port
            self.deviceID = deviceID
            self.localKey = localKey
            self.version = version
            self.connectTimeout = connectTimeout
            self.responseTimeout = responseTimeout
        }
    }

    public nonisolated let statusUpdates: AsyncStream<DPMap>
    private let statusContinuation: AsyncStream<DPMap>.Continuation

    private let config: Configuration
    private let clock: any Clock<Duration>
    private var transport: TCPTransport?
    private var codec: TuyaCodec
    private var nextSeq: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    private var readTask: Task<Void, Never>?
    private var isClosed = false
    /// True once the TCP connection was established at least once.
    public private(set) var hasConnected = false

    private struct Pending {
        let expectedCommand: UInt32
        let continuation: CheckedContinuation<TuyaFrame, Error>
        let timer: Task<Void, Never>
    }

    public init(configuration: Configuration, clock: any Clock<Duration> = ContinuousClock()) {
        self.config = configuration
        self.clock = clock
        self.codec = TuyaCodec(version: configuration.version, key: Data(configuration.localKey.utf8))
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: DPMap.self, bufferingPolicy: .bufferingNewest(32))
    }

    public var version: TuyaVersion { config.version }

    // MARK: Connect

    /// Opens the TCP connection (3 s default timeout) and, for 3.4/3.5, negotiates the session key.
    public func connect() async throws {
        guard config.localKey.utf8.count == 16 else { throw TuyaError.invalidKey }
        let transport = TCPTransport(host: config.host, port: config.port)
        self.transport = transport
        do {
            try await withTimeout(config.connectTimeout) { try await transport.connect() }
        } catch {
            transport.cancel()
            self.transport = nil
            throw error
        }
        hasConnected = true
        startReading(transport)
        if config.version != .v33 {
            do { try await negotiate() } catch {
                close()
                throw error
            }
        }
    }

    private func negotiate() async throws {
        let neg = SessionNegotiation(version: config.version, localKey: Data(config.localKey.utf8))
        let reply: TuyaFrame
        do {
            reply = try await request(command: TuyaCommand.sessKeyNegStart, payload: neg.step1Payload)
        } catch TuyaError.timeout, TuyaError.connectionClosed {
            // Devices silently drop a client whose negotiation frame fails their integrity check:
            // per spec, a failed session negotiation is reported as an invalid local key.
            throw TuyaError.invalidKey
        }
        let (remoteNonce, step3Payload) = try neg.processStep2(reply.payload)
        let sessionKey = try neg.sessionKey(remoteNonce: remoteNonce)
        // Encode step 3 with the local key, then switch codecs *before* sending so that anything the
        // device pushes right after negotiation is decoded with the session key.
        let step3 = try codec.encode(command: TuyaCommand.sessKeyNegFinish, seq: takeSeq(), payload: step3Payload)
        codec = codec.with(key: sessionKey)
        try await transport?.send(step3)
    }

    // MARK: Operations

    /// Queries the current datapoints.
    public func queryDPs() async throws -> DPMap {
        let q = TuyaPayloads.query(version: config.version, deviceID: config.deviceID)
        let reply = try await request(command: q.command, payload: q.payload)
        try Self.checkRetcode(reply)
        return try TuyaPayloads.parseDPs(reply.payload)
    }

    /// Sets datapoints in one CONTROL frame; returns when the device acknowledges it.
    public func setDPs(_ dps: DPMap) async throws {
        let c = TuyaPayloads.control(version: config.version, deviceID: config.deviceID, dps: dps)
        let reply = try await request(command: c.command, payload: c.payload)
        try Self.checkRetcode(reply)
    }

    /// Sends a heartbeat and waits for the reply.
    public func heartbeat() async throws {
        _ = try await request(command: TuyaCommand.heartBeat, payload: TuyaPayloads.heartbeat(deviceID: config.deviceID))
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        transport?.cancel()
        transport = nil
        readTask?.cancel()
        failAll(TuyaError.connectionClosed)
        statusContinuation.finish()
    }

    // MARK: Request / response plumbing

    private func takeSeq() -> UInt32 {
        defer { nextSeq &+= 1 }
        return nextSeq
    }

    private static func expectedResponse(to command: UInt32) -> UInt32 {
        command == TuyaCommand.sessKeyNegStart ? TuyaCommand.sessKeyNegResp : command
    }

    private static func checkRetcode(_ frame: TuyaFrame) throws {
        if let rc = frame.retcode, rc != 0 { throw TuyaError.protocol("device returned error code \(rc)") }
    }

    private func request(command: UInt32, payload: Data) async throws -> TuyaFrame {
        guard let transport, !isClosed else { throw TuyaError.connectionClosed }
        let seq = takeSeq()
        let wire = try codec.encode(command: command, seq: seq, payload: payload)
        let timeout = config.responseTimeout
        let clock = self.clock
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TuyaFrame, Error>) in
                let timer = Task { [weak self] in
                    do { try await clock.sleep(for: timeout) } catch { return }
                    await self?.resolve(seq: seq, with: .failure(TuyaError.timeout))
                }
                pending[seq] = Pending(expectedCommand: Self.expectedResponse(to: command), continuation: cont, timer: timer)
                Task { [weak self] in
                    do { try await transport.send(wire) } catch {
                        await self?.resolve(seq: seq, with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.resolve(seq: seq, with: .failure(CancellationError())) }
        }
    }

    private func resolve(seq: UInt32, with result: Result<TuyaFrame, Error>) {
        guard let p = pending.removeValue(forKey: seq) else { return }
        p.timer.cancel()
        p.continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending = [:]
        for (_, p) in all {
            p.timer.cancel()
            p.continuation.resume(throwing: error)
        }
    }

    private func startReading(_ transport: TCPTransport) {
        readTask = Task { [weak self] in
            do {
                for try await raw in transport.frames {
                    await self?.handleIncoming(raw)
                }
                await self?.readEnded(TuyaError.connectionClosed)
            } catch {
                await self?.readEnded(error)
            }
        }
    }

    private func readEnded(_ error: Error) {
        failAll(error)
        statusContinuation.finish()
        isClosed = true
        transport?.cancel()
        transport = nil
    }

    private func handleIncoming(_ raw: Data) {
        let frame: TuyaFrame
        do {
            frame = try codec.decode(raw)
        } catch {
            // Integrity/decrypt failure: during negotiation this is a wrong key; either way the stream is unusable.
            failAll(error)
            transport?.cancel()
            return
        }
        if frame.command == TuyaCommand.status {
            if let dps = try? TuyaPayloads.parseDPs(frame.payload), !dps.isEmpty { statusContinuation.yield(dps) }
            return
        }
        if pending[frame.seq] != nil {
            resolve(seq: frame.seq, with: .success(frame))
            return
        }
        // Some devices do not echo the sequence number: fall back to the oldest request expecting this command.
        if let seq = pending.filter({ $0.value.expectedCommand == frame.command }).keys.min() {
            resolve(seq: seq, with: .success(frame))
        }
    }

    // MARK: Timeout helper

    private func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: duration)
                throw TuyaError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
