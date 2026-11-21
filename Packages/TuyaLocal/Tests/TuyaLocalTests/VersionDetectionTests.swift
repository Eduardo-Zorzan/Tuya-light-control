import Foundation
import Testing

@testable import TuyaLocal

@Suite("Version auto-detection", .serialized)
struct VersionDetectionTests {
    private func detect(_ device: FakeTuyaDevice, key: String = "0123456789abcdef", preferred: TuyaVersion? = nil) async throws
        -> DetectionResult
    {
        try await VersionDetector.detect(
            host: "127.0.0.1", port: device.port, deviceID: "devid0123456789", localKey: key, preferred: preferred,
            connectTimeout: .seconds(2), responseTimeout: .milliseconds(400))
    }

    @Test(arguments: TuyaVersion.allCases)
    func resolvesWhateverTheDeviceSpeaks(version: TuyaVersion) async throws {
        let device = FakeTuyaDevice(version: version)
        try await device.start()
        defer { device.stop() }
        let result = try await detect(device)
        #expect(result.version == version)
        #expect(result.dps[20] == .bool(true))
    }

    @Test func versionOnlyDeviceResolvesTo34() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        #expect(try await detect(device).version == .v34)
    }

    @Test func wrongPreferredVersionFallsBack() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        #expect(try await detect(device, preferred: .v33).version == .v34)
    }

    @Test func correctPreferredVersionIsTriedFirst() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        defer { device.stop() }
        _ = try await detect(device, preferred: .v33)
        // Only one connection: no failed 3.5/3.4 attempts before the preferred version.
        #expect(device.connectionsAccepted == 1)
    }

    @Test func wrongKeyOnEveryVersionReportsInvalidKey() async throws {
        let device = FakeTuyaDevice(version: .v34)
        try await device.start()
        defer { device.stop() }
        await #expect(throws: TuyaError.invalidKey) { _ = try await detect(device, key: "fedcba9876543210") }
    }

    @Test func refusedConnectionAbortsImmediately() async throws {
        let device = FakeTuyaDevice(version: .v33)
        try await device.start()
        let port = device.port
        device.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: TuyaError.connectionRefused) {
            _ = try await VersionDetector.detect(host: "127.0.0.1", port: port, deviceID: "x", localKey: "0123456789abcdef")
        }
    }
}
