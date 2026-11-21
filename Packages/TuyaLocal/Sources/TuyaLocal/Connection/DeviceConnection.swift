import Foundation

/// Owns the connection to one light and keeps it alive.
///
/// ```
///  Idle ──start──▶ Connecting ──negotiated──▶ Connected
///    ▲                 │ fail                      │ heartbeat timeout / socket error /
///    │                 ▼                           ▼ send unconfirmed / reconnectNow
///    └────────── Offline|Error (backoff) ◀─────────┘
/// ```
///
/// Callers express *desired state* with `setDesired`; the actor coalesces it (latest value per datapoint
/// wins), sends at most one CONTROL frame per `sendInterval`, confirms delivery, retries once on a fresh
/// connection, and replays still-fresh changes after a reconnect. Time is injected for deterministic tests.
public actor DeviceConnection {
    public nonisolated let statuses: AsyncStream<ConnectionStatus>
    public nonisolated let states: AsyncStream<ReportedState>
    public nonisolated let events: AsyncStream<ConnectionEvent>

    private let statusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private let stateContinuation: AsyncStream<ReportedState>.Continuation
    private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation

    private var config: DeviceConfiguration
    private let timing: ConnectionTiming
    private let clock: any Clock<Duration>
    private let connector: DeviceConnector
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Duration

    private(set) public var status: ConnectionStatus = .idle
    private(set) public var reported = ReportedState()

    private var backoff: Backoff
    private var runTask: Task<Void, Never>?
    private var attemptTask: Task<(client: TuyaClient, version: TuyaVersion, dps: DPMap), Error>?
    private var backoffTask: Task<Void, Never>?
    private var current: TuyaClient?
    private var isShutdown = false
    private var immediateRetry = false

    // Desired-state coalescing
    private struct Desire {
        var value: DPValue
        var time: Duration
        var seq: Int
    }
    private var desired: [Int: Desire] = [:]
    private var desireSeq = 0
    private var lastSend: Duration?
    private var unconfirmedFailures = 0
    private var failureReported = false
    private var lastActivity: Duration = .zero

    // Wake primitive for the send loop
    private var wakeFlag = false
    private var wakeWaiter: CheckedContinuation<Void, Never>?

    public init<C: Clock<Duration>>(
        configuration: DeviceConfiguration,
        timing: ConnectionTiming = ConnectionTiming(),
        clock: C = ContinuousClock(),
        connector: @escaping DeviceConnector = DefaultConnector.connect
    ) {
        self.config = configuration
        self.timing = timing
        self.clock = clock
        self.connector = connector
        let start = clock.now
        self.sleep = { try await clock.sleep(for: $0) }
        self.now = { start.duration(to: clock.now) }
        self.backoff = Backoff(base: timing.backoffBase, cap: timing.backoffCap)
        (statuses, statusContinuation) = AsyncStream.makeStream(of: ConnectionStatus.self, bufferingPolicy: .unbounded)
        (states, stateContinuation) = AsyncStream.makeStream(of: ReportedState.self, bufferingPolicy: .bufferingNewest(16))
        (events, eventContinuation) = AsyncStream.makeStream(of: ConnectionEvent.self, bufferingPolicy: .unbounded)
        statusContinuation.yield(.idle)
    }

    public var deviceID: String { config.deviceID }
    public var configuration: DeviceConfiguration { config }

    // MARK: Inputs

    /// Starts connecting and keeps the link alive until `shutdown()`.
    public func start() {
        guard runTask == nil, !isShutdown else { return }
        runTask = Task { await self.runLoop() }
    }

    /// Merges a patch into the desired state. Never blocks on the network.
    public func setDesired(_ patch: DPMap) {
        guard !isShutdown, !patch.isEmpty else { return }
        let t = now()
        for (key, value) in patch {
            desireSeq += 1
            desired[key] = Desire(value: value, time: t, seq: desireSeq)
        }
        failureReported = false
        switch status {
        case .offline, .error:
            // Known unreachable: tell the UI now. If the light returns within the replay window the
            // change is still applied and `.applied` follows.
            failureReported = true
            eventContinuation.yield(.applyFailed)
        default:
            break
        }
        wake()
    }

    /// Re-reads the datapoints from a connected light (e.g. when the popover opens).
    public func refresh() async {
        guard let client = current, status.isConnected else { return }
        if let dps = try? await client.queryDPs() {
            lastActivity = now()
            merge(dps)
        }
    }

    /// Drops the current connection (if any), skips the backoff wait and reconnects immediately.
    public func reconnectNow() {
        guard !isShutdown, runTask != nil else { return }
        Log.info(.connection, "reconnect requested", device: config.deviceID)
        immediateRetry = true
        backoffTask?.cancel()
        attemptTask?.cancel()
        current?.closeDetached()
    }

    /// The light moved to a new address (e.g. DHCP): reconnect there.
    public func updateAddress(_ host: String, version: TuyaVersion? = nil) {
        var changed = false
        if host != config.host { config.host = host; changed = true }
        if let version, config.version == nil { config.version = version }
        if changed {
            Log.info(.connection, "address updated", device: config.deviceID, address: host)
            reconnectNow()
        }
    }

    public func updateKey(_ localKey: String) {
        guard localKey != config.localKey else { return }
        config.localKey = localKey
        reconnectNow()
    }

    /// Stops everything. Sends no commands to the light (it keeps its current state).
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        backoffTask?.cancel()
        attemptTask?.cancel()
        current?.closeDetached()
        runTask?.cancel()
        wakeWaiter?.resume()
        wakeWaiter = nil
        statusContinuation.finish()
        stateContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: Run loop

    private func runLoop() async {
        while !isShutdown, !Task.isCancelled {
            setStatus(.connecting)
            var failure: Error?
            let attempt = Task { try await self.connector(self.config, self.timing, self.clock) }
            attemptTask = attempt
            do {
                let (client, version, dps) = try await attempt.value
                attemptTask = nil
                if isShutdown { client.closeDetached(); break }
                current = client
                if config.version != version {
                    config.version = version
                    eventContinuation.yield(.versionResolved(version))
                }
                backoff.reset()
                lastActivity = now()
                merge(dps)
                dropStaleDesires()
                setStatus(.connected)
                Log.info(.connection, "connected", device: config.deviceID)
                try await serve(client)
            } catch {
                failure = error
            }
            attemptTask = nil
            current?.closeDetached()
            current = nil
            if isShutdown || Task.isCancelled { break }
            await handleFailure(failure)
        }
    }

    private func handleFailure(_ failure: Error?) async {
        if immediateRetry {
            // reconnectNow() / first unconfirmed send: go straight back to connecting without flashing "offline".
            immediateRetry = false
            return
        }
        if failure is CancellationError { return }
        let delay = backoff.nextDelay()
        let nextRetry = Date().addingTimeInterval(delay.timeInterval)
        let mapped = failure.flatMap { $0 as? TuyaError }
        switch mapped {
        case .invalidKey: setStatus(.error(.invalidKey, nextRetry: nextRetry))
        case .connectionRefused: setStatus(.error(.connectionRefused, nextRetry: nextRetry))
        case .localNetworkDenied: setStatus(.error(.localNetworkDenied, nextRetry: nextRetry))
        case .protocol: setStatus(.error(.unsupportedProtocol, nextRetry: nextRetry))
        default: setStatus(.offline(nextRetry: nextRetry))
        }
        Log.info(.connection, "connection lost or failed", device: config.deviceID, error: failure)
        if !desired.isEmpty, !failureReported {
            failureReported = true
            eventContinuation.yield(.applyFailed)
        }
        let sleep = self.sleep
        let waiter = Task<Void, Never> { do { try await sleep(delay) } catch {} }
        backoffTask = waiter
        await waiter.value
        backoffTask = nil
        immediateRetry = false
    }

    // MARK: Serving a live connection

    private func serve(_ client: TuyaClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.heartbeatLoop(client) }
            group.addTask { try await self.statusLoop(client) }
            group.addTask { try await self.sendLoop(client) }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Heartbeat every `heartbeatInterval` of *inactivity*; a missing reply within `responseTimeout` kills the link.
    private func heartbeatLoop(_ client: TuyaClient) async throws {
        while true {
            let wait = timing.heartbeatInterval - (now() - lastActivity)
            if wait > .zero {
                try await sleep(wait)
                continue
            }
            try await client.heartbeat()
            lastActivity = now()
        }
    }

    private func statusLoop(_ client: TuyaClient) async throws {
        for await dps in client.statusUpdates {
            lastActivity = now()
            merge(dps)
        }
        throw TuyaError.connectionClosed
    }

    private func sendLoop(_ client: TuyaClient) async throws {
        while true {
            if desired.isEmpty { await waitForWake() }
            try Task.checkCancellation()
            if let last = lastSend {
                let since = now() - last
                if since < timing.sendInterval { try await sleep(timing.sendInterval - since) }
            }
            guard !desired.isEmpty else { continue }
            let snapshot = desired
            lastSend = now()
            do {
                try await client.setDPs(snapshot.mapValues(\.value))
            } catch {
                if error is CancellationError { throw error }
                noteSendFailure()
                throw error
            }
            lastActivity = now()
            unconfirmedFailures = 0
            for (key, sent) in snapshot where desired[key]?.seq == sent.seq { desired[key] = nil }
            merge(snapshot.mapValues(\.value))
            if desired.isEmpty { eventContinuation.yield(.applied) }
        }
    }

    /// First unconfirmed send → reconnect immediately and resend; second → tell the UI.
    private func noteSendFailure() {
        unconfirmedFailures += 1
        if unconfirmedFailures == 1 {
            immediateRetry = true
        } else {
            failureReported = true
            eventContinuation.yield(.applyFailed)
        }
    }

    private func dropStaleDesires() {
        let t = now()
        let stale = desired.filter { t - $0.value.time > timing.staleDesireAge }.keys
        guard !stale.isEmpty else { return }
        for key in stale { desired[key] = nil }
        eventContinuation.yield(.applyFailed)
    }

    // MARK: Helpers

    private func setStatus(_ new: ConnectionStatus) {
        guard new != status else { return }
        status = new
        statusContinuation.yield(new)
    }

    private func merge(_ dps: DPMap) {
        guard !dps.isEmpty else { return }
        var next = reported
        next.dps.merge(dps) { _, new in new }
        guard next != reported else { return }
        reported = next
        stateContinuation.yield(next)
    }

    private func wake() {
        if let waiter = wakeWaiter {
            wakeWaiter = nil
            waiter.resume()
        } else {
            wakeFlag = true
        }
    }

    private func waitForWake() async {
        if wakeFlag {
            wakeFlag = false
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                wakeWaiter = cont
            }
        } onCancel: {
            Task { await self.wake() }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (s, atto) = components
        return TimeInterval(s) + TimeInterval(atto) / 1e18
    }
}

extension TuyaClient {
    /// Closes the client from a context that must not suspend.
    nonisolated func closeDetached() {
        Task { await self.close() }
    }
}
