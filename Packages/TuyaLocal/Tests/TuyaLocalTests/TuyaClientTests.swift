import Foundation
import Testing

@testable import TuyaLocal

private let goodKey = "0123456789abcdef"

private func config(
    _ device: FakeTuyaDevice, key: String = goodKey, version: TuyaVersion? = nil,
    response: Duration = .seconds(2)
) -> TuyaClient.Configuration {
    .init(
        host: "127.0.0.1", port: device.port, deviceID: "devid0123456789", localKey: key,
        version: version ?? device.version, connectTimeout: .seconds(2), responseTimeout: response)
}

@Suite("TuyaClient against fake device", .serialized)
struct TuyaClientTests {
    @Test(arguments: TuyaVersion.allCases)
    func connectQuerySetHeartbeat(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let client = TuyaClient(configuration: config(device))
        try await client.connect()

        let dps = try await client.queryDPs()
        #expect(dps[20] == .bool(true))
        #expect(dps[22] == .int(500))
        #expect(dps[24] == .string("003d03e803e8"))

        try await client.setDPs([20: .bool(false), 22: .int(120)])
        #expect(device.controls == [[20: .bool(false), 22: .int(120)]])
        #expect(device.dps[20] == .bool(false))
        let pushed = await firstValue(of: client.statusUpdates)
        #expect(pushed?[22] == .int(120))

        try await client.heartbeat()
        #expect(device.heartbeats == 1)
        await client.close()
    }

    @Test(arguments: TuyaVersion.allCases)
    func devicePushedStatusIsDelivered(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let client = TuyaClient(configuration: config(device))
        try await client.connect()
        #expect(await waitUntil { device.readyConnections == 1 })
        device.push([20: .bool(false)])
        let pushed = await firstValue(of: client.statusUpdates)
        #expect(pushed?[20] == .bool(false))
        await client.close()
    }

    @Test(arguments: TuyaVersion.allCases)
    func wrongLocalKeyReportsInvalidKey(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let client = TuyaClient(configuration: config(device, key: "fedcba9876543210"))
        await #expect(throws: TuyaError.invalidKey) {
            try await client.connect()
            // 3.3 has no negotiation: the wrong key shows on the first reply.
            _ = try await client.queryDPs()
        }
        await client.close()
    }

    @Test func malformedKeyLengthIsInvalidKey() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        let client = TuyaClient(configuration: config(device, key: "short"))
        await #expect(throws: TuyaError.invalidKey) { try await client.connect() }
    }

    @Test func refusedConnectionIsReported() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        let cfg = config(device)
        device.stop()  // nothing listens on that port any more
        try await Task.sleep(for: .milliseconds(100))
        let client = TuyaClient(configuration: cfg)
        await #expect(throws: TuyaError.connectionRefused) { try await client.connect() }
    }

    @Test func silentDeviceTimesOut() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        device.behavior.replyHeartbeat = false
        let client = TuyaClient(configuration: config(device, response: .milliseconds(300)))
        try await client.connect()
        await #expect(throws: TuyaError.timeout) { try await client.heartbeat() }
        await client.close()
    }

    @Test func requestsFailWhenDeviceDropsTheConnection() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        device.behavior.replyHeartbeat = false
        let client = TuyaClient(configuration: config(device, response: .seconds(5)))
        try await client.connect()
        let inflight = Task { try await client.heartbeat() }
        try await Task.sleep(for: .milliseconds(150))
        device.dropConnections()
        await #expect(throws: TuyaError.self) { try await inflight.value }
        await client.close()
    }
}
