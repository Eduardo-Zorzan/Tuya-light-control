import Clocks
import Foundation
import Testing

@testable import TuyaLocal

@Suite("DeviceConnection", .serialized)
struct DeviceConnectionTests {
    // MARK: 4.1 state machine

    @Test func publishesStatusTransitionsInOrder() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.map(StatusKind.init).last == .connected })

        device.goOffline()
        #expect(await waitUntil { rec.items.map(StatusKind.init).last == .offline })
        try await device.goOnline()
        await conn.reconnectNow()
        #expect(await waitUntil { rec.items.map(StatusKind.init).last == .connected })

        #expect(rec.items.map(StatusKind.init) == [.idle, .connecting, .connected, .offline, .connecting, .connected])
        await conn.shutdown()
    }

    @Test(arguments: TuyaVersion.allCases)
    func reportsStateAndResolvesVersion(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        var cfg = makeConfig(device)
        cfg.version = nil  // unknown: must be detected and remembered
        let conn = DeviceConnection(configuration: cfg, clock: TestClock<Duration>())
        let events = Recorder(conn.events)
        let states = Recorder(conn.states)
        await conn.start()
        #expect(await waitUntil { events.items.contains(.versionResolved(version)) })
        #expect(await waitUntil { states.items.last?.dps[22] == .int(500) })
        #expect(await conn.configuration.version == version)
        await conn.shutdown()
    }

    @Test func devicePushesUpdateReportedState() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        let conn = DeviceConnection(configuration: makeConfig(device), clock: TestClock<Duration>())
        let states = Recorder(conn.states)
        await conn.start()
        #expect(await waitUntil { device.readyConnections == 1 })
        device.push([22: .int(900)])
        #expect(await waitUntil { states.items.last?.dps[22] == .int(900) })
        await conn.shutdown()
    }

    // MARK: 4.2 heartbeat

    @Test func silentLightGoesOfflineWithinFifteenSeconds() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await settle()

        device.behavior.replyHeartbeat = false  // light stops answering (unplugged)
        await clock.advance(by: .seconds(10))  // heartbeat due
        #expect(await waitUntil { device.heartbeats == 1 })
        await settle()
        await clock.advance(by: .seconds(5))  // reply deadline
        // 10 s + 5 s = 15 s of virtual time in total.
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .offline })
        await conn.shutdown()
    }

    @Test func answeredHeartbeatsKeepTheLinkUp() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await settle()
        for expected in 1...3 {
            await clock.advance(by: .seconds(10))
            #expect(await waitUntil { device.heartbeats == expected })
            await settle()
        }
        #expect(rec.items.last == .connected)
        #expect(device.connectionsAccepted == 1)
        await conn.shutdown()
    }

    // MARK: 4.3 backoff and reconnectNow

    @Test func backoffGrowsAndResetsAfterSuccess() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()

        func nextRetryDelay() async -> TimeInterval? {
            guard await waitUntil({ if case .error = rec.items.last { return true } else { return false } }) else { return nil }
            if case .error(_, let when)? = rec.items.last { return when.timeIntervalSinceNow }
            return nil
        }
        let first = try #require(await nextRetryDelay())
        #expect((0.7...1.3).contains(first))  // ~1 s ± jitter

        let before = rec.items.count
        await clock.advance(by: .seconds(2))  // second attempt fails -> ~2 s
        #expect(await waitUntil { rec.items.count > before + 1 })
        guard case .error(_, let secondRetry)? = rec.items.last else { Issue.record("expected error status"); return }
        #expect(secondRetry.timeIntervalSinceNow > 1.4)

        try await device.goOnline()
        await conn.reconnectNow()  // no clock advance needed
        #expect(await waitUntil { rec.items.last == .connected })

        // After success the schedule restarts at ~1 s.
        device.goOffline()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .offline })
        guard case .offline(let afterReset)? = rec.items.last else { Issue.record("expected offline"); return }
        #expect(afterReset.timeIntervalSinceNow < 1.5)
        await conn.shutdown()
    }

    @Test func reconnectNowSkipsTheBackoffWait() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .error(.connectionRefused) })
        try await device.goOnline()
        let started = ContinuousClock.now
        await conn.reconnectNow()
        #expect(await waitUntil { rec.items.last == .connected })
        #expect(ContinuousClock.now - started < .seconds(2))  // the 1 s virtual backoff never had to elapse
        await conn.shutdown()
    }

    @Test func reconnectNowDropsAHealthyConnectionAndReconnects() async throws {
        let device = FakeTuyaDevice(version: .v35)
        try await device.start()
        defer { device.stop() }
        let conn = DeviceConnection(configuration: makeConfig(device), clock: TestClock<Duration>())
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await conn.reconnectNow()
        #expect(await waitUntil { device.connectionsAccepted == 2 && rec.items.last == .connected })
        // No "offline" flash for an intentional reconnect.
        #expect(!rec.items.map(StatusKind.init).contains(.offline))
        await conn.shutdown()
    }

    // MARK: 4.4 coalescing

    @Test(arguments: [TuyaVersion.v33, .v35])
    func fiftyBrightnessPatchesCollapseToFewFramesAndEndOnTheLastValue(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let conn = DeviceConnection(configuration: makeConfig(device), timing: fastTiming())
        let rec = Recorder(conn.statuses)
        let events = Recorder(conn.events)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })

        for i in 1...50 { await conn.setDesired([22: .int(100 + i)]) }
        #expect(await waitUntil { device.dps[22] == .int(150) })
        #expect(await waitUntil { events.items.contains(.applied) })
        let frames = device.controls
        #expect(frames.count <= 6, "expected few frames, got \(frames.count)")
        #expect(frames.last?[22] == .int(150))
        // Nothing stale after the release.
        let count = frames.count
        await settle(300)
        #expect(device.controls.count == count)
        await conn.shutdown()
    }

    @Test func differentDatapointsMergeIntoOneFrame() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        var timing = fastTiming()
        timing.sendInterval = .milliseconds(200)
        let conn = DeviceConnection(configuration: makeConfig(device), timing: timing)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await conn.setDesired([20: .bool(true)])  // goes out immediately
        #expect(await waitUntil { device.controls.count == 1 })
        await conn.setDesired([21: .string("colour")])
        await conn.setDesired([24: .string("00ff03e803e8")])
        await conn.setDesired([21: .string("white")])  // overwrites before it was sent
        #expect(await waitUntil { device.controls.count == 2 })
        #expect(device.controls[1] == [21: .string("white"), 24: .string("00ff03e803e8")])
        await conn.shutdown()
    }

    // MARK: 4.5 confirmation, retry, replay

    @Test func lostCommandIsResentOnAFreshConnection() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        device.behavior.swallowControls = 1  // the first frame vanishes (dead socket)
        let conn = DeviceConnection(configuration: makeConfig(device), timing: fastTiming())
        let rec = Recorder(conn.statuses)
        let events = Recorder(conn.events)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })

        await conn.setDesired([20: .bool(false)])
        #expect(await waitUntil(timeout: .seconds(5)) { device.dps[20] == .bool(false) })
        #expect(device.controls.count == 2)
        #expect(device.connectionsAccepted == 2)  // resent on a *fresh* connection
        #expect(events.items.contains(.applied))
        #expect(!events.items.contains(.applyFailed))
        await conn.shutdown()
    }

    @Test func secondFailureTellsTheUI() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        device.behavior.swallowControls = 100
        let conn = DeviceConnection(configuration: makeConfig(device), timing: fastTiming())
        let rec = Recorder(conn.statuses)
        let events = Recorder(conn.events)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await conn.setDesired([20: .bool(false)])
        #expect(await waitUntil(timeout: .seconds(5)) { events.items.contains(.applyFailed) })
        #expect(device.connectionsAccepted >= 2)
        #expect(device.controls.count == 2)  // exactly one retry, not an endless loop
        #expect(device.dps[20] == .bool(true))  // never applied
        await conn.shutdown()
    }

    @Test func freshDesireIsReplayedAfterReconnect() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .error(.connectionRefused) })

        await conn.setDesired([21: .string("colour"), 24: .string("0000ffff03e8")])
        await clock.advance(by: .seconds(5))  // brief outage
        try await device.goOnline()
        await conn.reconnectNow()
        #expect(await waitUntil { rec.items.last == .connected })
        #expect(await waitUntil { device.dps[24] == .string("0000ffff03e8") })
        #expect(device.controls == [[21: .string("colour"), 24: .string("0000ffff03e8")]])
        await conn.shutdown()
    }

    @Test func staleDesireIsDiscardedInsteadOfReplayed() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let clock = TestClock<Duration>()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: clock)
        let rec = Recorder(conn.statuses)
        let events = Recorder(conn.events)
        await conn.start()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .error(.connectionRefused) })

        await conn.setDesired([20: .bool(false)])
        await clock.advance(by: .seconds(61))  // older than the 60 s window
        try await device.goOnline()
        await conn.reconnectNow()
        #expect(await waitUntil { rec.items.last == .connected })
        await settle(300)
        #expect(device.controls.isEmpty)
        #expect(device.dps[20] == .bool(true))
        #expect(events.items.contains(.applyFailed))
        await conn.shutdown()
    }

    @Test func changeToUnreachableLightIsReportedNotApplied() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: TestClock<Duration>())
        let rec = Recorder(conn.statuses)
        let events = Recorder(conn.events)
        await conn.start()
        #expect(await waitUntil { if case .error = rec.items.last { return true } else { return false } })
        await conn.setDesired([21: .string("colour")])
        await conn.reconnectNow()  // another failed attempt while a change is pending
        #expect(await waitUntil { events.items.contains(.applyFailed) })
        await conn.shutdown()
    }

    // MARK: 4.6 error mapping

    @Test(arguments: [TuyaVersion.v33, .v34, .v35])
    func wrongLocalKeyShowsInvalidKeyAndBacksOff(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let conn = DeviceConnection(
            configuration: makeConfig(device, key: "fedcba9876543210"), timing: fastTiming(), clock: TestClock<Duration>())
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .error(.invalidKey) })
        guard case .error(_, let retry)? = rec.items.last else { Issue.record("expected error"); return }
        #expect(retry.timeIntervalSinceNow > 0.5)  // follows the backoff schedule, not a tight loop
        await conn.shutdown()
    }

    @Test func refusedConnectionShowsAnotherAppMayBeConnected() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        device.goOffline()
        let conn = DeviceConnection(configuration: makeConfig(device), clock: TestClock<Duration>())
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { StatusKind(rec.items.last ?? .idle) == .error(.connectionRefused) })
        await conn.shutdown()
    }

    @Test func injectedErrorsMapToUserFacingStatuses() async throws {
        let cases: [(TuyaError, StatusKind)] = [
            (.localNetworkDenied, .error(.localNetworkDenied)),
            (.protocol("bad frame"), .error(.unsupportedProtocol)),
            (.invalidKey, .error(.invalidKey)),
            (.connectionRefused, .error(.connectionRefused)),
            (.timeout, .offline),
            (.connectionClosed, .offline),
        ]
        for (error, expected) in cases {
            let conn = DeviceConnection(
                configuration: DeviceConfiguration(deviceID: "x", host: "192.0.2.1", localKey: "0123456789abcdef"),
                clock: TestClock<Duration>(), connector: { _, _, _ in throw error })
            let rec = Recorder(conn.statuses)
            await conn.start()
            #expect(await waitUntil { rec.items.map(StatusKind.init).last == expected }, "\(error) should map to \(expected)")
            await conn.shutdown()
        }
    }

    // MARK: Address and key updates, shutdown

    @Test func addressUpdateReconnectsAtTheNewAddress() async throws {
        let seen = HostLog()
        let conn = DeviceConnection(
            configuration: DeviceConfiguration(deviceID: "x", host: "192.168.0.20", localKey: "0123456789abcdef"),
            clock: TestClock<Duration>(),
            connector: { cfg, _, _ in
                seen.add(cfg.host)
                throw TuyaError.timeout
            })
        await conn.start()
        #expect(await waitUntil { seen.hosts == ["192.168.0.20"] })
        await conn.updateAddress("192.168.0.31", version: .v34)  // discovery saw the light elsewhere
        #expect(await waitUntil { seen.hosts == ["192.168.0.20", "192.168.0.31"] })
        #expect(await conn.configuration.version == .v34)
        await conn.updateAddress("192.168.0.31")  // unchanged: no extra attempt
        await settle()
        #expect(seen.hosts.count == 2)
        await conn.shutdown()
    }

    @Test func shutdownSendsNothingAndClosesTheSocket() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        let conn = DeviceConnection(configuration: makeConfig(device), clock: TestClock<Duration>())
        let rec = Recorder(conn.statuses)
        await conn.start()
        #expect(await waitUntil { rec.items.last == .connected })
        await conn.shutdown()
        #expect(await waitUntil { device.openConnections == 0 })
        #expect(device.controls.isEmpty)
        #expect(device.dps == FakeTuyaDevice.defaultDPs)
    }
}

final class HostLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    func add(_ h: String) { lock.withLock { _hosts.append(h) } }
    var hosts: [String] { lock.withLock { _hosts } }
}
