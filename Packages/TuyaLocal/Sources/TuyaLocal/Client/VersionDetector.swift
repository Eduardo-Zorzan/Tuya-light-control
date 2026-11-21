import Foundation

/// Result of probing a device: the protocol version that worked and its current datapoints.
public struct DetectionResult: Sendable, Equatable {
    public var version: TuyaVersion
    public var dps: DPMap
}

/// Finds the protocol version a device speaks by trying the preferred version first
/// (e.g. from a discovery broadcast or the stored value), then 3.5 → 3.4 → 3.3.
public enum VersionDetector {
    public static func detect(
        host: String,
        port: UInt16 = 6668,
        deviceID: String,
        localKey: String,
        preferred: TuyaVersion? = nil,
        connectTimeout: Duration = .seconds(3),
        responseTimeout: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> DetectionResult {
        let (client, result) = try await connect(
            host: host, port: port, deviceID: deviceID, localKey: localKey, preferred: preferred,
            connectTimeout: connectTimeout, responseTimeout: responseTimeout, clock: clock)
        await client.close()
        return result
    }

    /// Like `detect`, but returns the connected client for the version that worked (left open).
    public static func connect(
        host: String,
        port: UInt16 = 6668,
        deviceID: String,
        localKey: String,
        preferred: TuyaVersion? = nil,
        connectTimeout: Duration = .seconds(3),
        responseTimeout: Duration = .seconds(2),
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> (client: TuyaClient, result: DetectionResult) {
        var order = TuyaVersion.detectionOrder
        if let preferred { order.removeAll { $0 == preferred }; order.insert(preferred, at: 0) }

        var sawInvalidKey = false
        var lastError: Error = TuyaError.timeout
        for version in order {
            try Task.checkCancellation()
            let client = TuyaClient(
                configuration: .init(
                    host: host, port: port, deviceID: deviceID, localKey: localKey, version: version,
                    connectTimeout: connectTimeout, responseTimeout: responseTimeout),
                clock: clock)
            do {
                try await client.connect()
                let dps = try await client.queryDPs()
                return (client, DetectionResult(version: version, dps: dps))
            } catch let error as TuyaError {
                await client.close()
                switch error {
                case .connectionRefused, .localNetworkDenied:
                    throw error  // not version-specific: another version cannot help
                case .invalidKey:
                    sawInvalidKey = true
                    lastError = error
                case .timeout where await isTCPLevelTimeout(client):
                    throw error
                default:
                    lastError = error
                }
            } catch {
                await client.close()
                throw error  // cancellation
            }
        }
        throw sawInvalidKey ? TuyaError.invalidKey : lastError
    }

    /// A timeout before the TCP connection came up means the host is unreachable for every version.
    private static func isTCPLevelTimeout(_ client: TuyaClient) async -> Bool {
        await !client.hasConnected
    }
}
