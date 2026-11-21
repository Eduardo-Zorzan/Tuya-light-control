import Clocks
import Foundation
import Testing

@testable import TuyaLocal

@Suite("DeviceManager", .serialized)
struct DeviceManagerTests {
    @Test func oneOfThreeLightsDownStillAppliesToTheOtherTwoImmediately() async throws {
        let a = FakeTuyaDevice(version: .v33)
        let b = FakeTuyaDevice(version: .v34)
        let c = FakeTuyaDevice(version: .v35)
        for d in [a, b, c] { try await d.start() }
        defer { [a, b, c].forEach { $0.stop() } }
        c.goOffline()  // the third light is unplugged

        let clock = TestClock<Duration>()  // never advanced: nothing may depend on timers elapsing
        let manager = DeviceManager(clock: clock)
        let updates = Recorder(manager.updates)
        await manager.add(makeConfig(a, id: "light-a"))
        await manager.add(makeConfig(b, id: "light-b"))
        await manager.add(makeConfig(c, id: "light-c"))

        @Sendable func status(_ id: String) -> StatusKind? {
            updates.items.compactMap { u -> StatusKind? in
                if case .status(let did, let s) = u, did == id { return StatusKind(s) }
                return nil
            }.last
        }
        #expect(await waitUntil { status("light-a") == .connected && status("light-b") == .connected })
        #expect(await waitUntil { status("light-c") == .error(.connectionRefused) })

        let started = ContinuousClock.now
        await manager.setDesired([20: .bool(false), 22: .int(777)])  // "all lights"
        #expect(await waitUntil(timeout: .seconds(2)) { a.dps[22] == .int(777) && b.dps[22] == .int(777) })
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(c.controls.isEmpty)
        // The offline light is reported as not updated.
        #expect(await waitUntil { updates.items.contains(.event(deviceID: "light-c", .applyFailed)) })
        await manager.shutdown()
    }

    @Test func targetsASingleLightOnly() async throws {
        let a = FakeTuyaDevice(version: .v34)
        let b = FakeTuyaDevice(version: .v34)
        for d in [a, b] { try await d.start() }
        defer { [a, b].forEach { $0.stop() } }
        let manager = DeviceManager(timing: fastTiming(), clock: ContinuousClock())
        let updates = Recorder(manager.updates)
        await manager.add(makeConfig(a, id: "a"))
        await manager.add(makeConfig(b, id: "b"))
        #expect(await waitUntil { a.readyConnections == 1 && b.readyConnections == 1 })
        await manager.setDesired([20: .bool(false)], for: ["b"])
        #expect(await waitUntil { b.dps[20] == .bool(false) })
        await settle(300)
        #expect(a.controls.isEmpty)
        _ = updates
        await manager.shutdown()
    }

    @Test func removingALightShutsItsConnectionDown() async throws {
        let a = FakeTuyaDevice(version: .v33)
        try await a.start()
        defer { a.stop() }
        let manager = DeviceManager(clock: TestClock<Duration>())
        await manager.add(makeConfig(a, id: "a"))
        #expect(await waitUntil { a.readyConnections == 1 })
        await manager.remove(deviceID: "a")
        #expect(await waitUntil { a.openConnections == 0 })
        #expect(await manager.deviceIDs.isEmpty)
        await manager.shutdown()
    }

    @Test func discoveryBroadcastUpdatesTheStoredAddress() async throws {
        let seen = HostLog()
        let manager = DeviceManager(
            clock: TestClock<Duration>(),
            connector: { cfg, _, _ in
                seen.add(cfg.host)
                throw TuyaError.timeout
            })
        await manager.add(DeviceConfiguration(deviceID: "bf-light", host: "192.168.0.20", localKey: "0123456789abcdef"))
        #expect(await waitUntil { seen.hosts == ["192.168.0.20"] })

        let (stream, cont) = AsyncStream.makeStream(of: DiscoveredDevice.self)
        await manager.consume(discovery: stream)
        cont.yield(DiscoveredDevice(deviceID: "someone-else", ip: "192.168.0.99"))  // not ours: ignored
        cont.yield(DiscoveredDevice(deviceID: "bf-light", ip: "192.168.0.31", version: .v34))
        #expect(await waitUntil { seen.hosts == ["192.168.0.20", "192.168.0.31"] })
        #expect(await manager.connection(for: "bf-light")?.configuration.host == "192.168.0.31")
        cont.finish()
        await manager.shutdown()
    }

    @Test func reconnectAllBypassesBackoffForEveryLight() async throws {
        let a = FakeTuyaDevice(version: .v33)
        let b = FakeTuyaDevice(version: .v34)
        for d in [a, b] { try await d.start() }
        defer { [a, b].forEach { $0.stop() } }
        a.goOffline(); b.goOffline()
        let manager = DeviceManager(clock: TestClock<Duration>())
        let updates = Recorder(manager.updates)
        await manager.add(makeConfig(a, id: "a"))
        await manager.add(makeConfig(b, id: "b"))
        #expect(await waitUntil { updates.items.count >= 6 })  // both reached an error state
        try await a.goOnline(); try await b.goOnline()
        await manager.reconnectAll()  // e.g. wake from sleep
        #expect(await waitUntil { a.readyConnections == 1 && b.readyConnections == 1 })
        await manager.shutdown()
    }
}
