import Foundation

/// Everything needed to reach one light.
public struct DeviceConfiguration: Sendable, Equatable {
    public var deviceID: String
    public var host: String
    public var port: UInt16
    public var localKey: String
    /// Last protocol version known to work; `nil` means "detect".
    public var version: TuyaVersion?

    public init(deviceID: String, host: String, port: UInt16 = 6668, localKey: String, version: TuyaVersion? = nil) {
        self.deviceID = deviceID
        self.host = host
        self.port = port
        self.localKey = localKey
        self.version = version
    }
}

/// Why a light is in the error state.
public enum ConnectionFailure: Sendable, Equatable {
    case invalidKey
    /// Refused/reset: another app may hold the light's single local connection.
    case connectionRefused
    case localNetworkDenied
    case unsupportedProtocol
}

/// Per-light connection status shown in the UI.
public enum ConnectionStatus: Sendable, Equatable {
    case idle
    case connecting
    case connected
    /// Unreachable; the next automatic attempt is at `nextRetry`.
    case offline(nextRetry: Date)
    case error(ConnectionFailure, nextRetry: Date)

    public var isConnected: Bool { self == .connected }
}

public enum ConnectionEvent: Sendable, Equatable {
    /// A requested change could not be delivered (unconfirmed twice, light unreachable, or discarded as stale).
    case applyFailed
    /// All pending changes were acknowledged by the light.
    case applied
    /// The protocol version that worked; persist it so later connections try it first.
    case versionResolved(TuyaVersion)
}

/// The light's datapoints as last reported (merged across queries and pushes).
public struct ReportedState: Sendable, Equatable {
    public var dps: DPMap
    public init(dps: DPMap = [:]) { self.dps = dps }
}

/// Tunable timings; defaults are the product values from the spec.
public struct ConnectionTiming: Sendable {
    public var heartbeatInterval: Duration = .seconds(10)
    /// Reply deadline for heartbeats and commands.
    public var responseTimeout: Duration = .seconds(5)
    public var connectTimeout: Duration = .seconds(3)
    /// Minimum spacing between CONTROL frames to one light.
    public var sendInterval: Duration = .milliseconds(80)
    /// Pending changes older than this are discarded instead of replayed.
    public var staleDesireAge: Duration = .seconds(60)
    public var backoffBase: Duration = .seconds(1)
    public var backoffCap: Duration = .seconds(30)

    public init() {}
}

/// Opens a connection to a light and returns the live client, the working version and the first DP query.
public typealias DeviceConnector =
    @Sendable (
        _ configuration: DeviceConfiguration, _ timing: ConnectionTiming, _ clock: any Clock<Duration>
    ) async throws -> (client: TuyaClient, version: TuyaVersion, dps: DPMap)

public enum DefaultConnector {
    public static let connect: DeviceConnector = { config, timing, clock in
        // No address yet (added without an IP): wait for discovery, which calls `updateAddress` and reconnects at once.
        guard !config.host.isEmpty else { throw TuyaError.timeout }
        let (client, result) = try await VersionDetector.connect(
            host: config.host, port: config.port, deviceID: config.deviceID, localKey: config.localKey,
            preferred: config.version, connectTimeout: timing.connectTimeout,
            responseTimeout: timing.responseTimeout, clock: clock)
        return (client, result.version, result.dps)
    }
}

/// Exponential backoff with jitter: `min(cap, base · 2^attempt · (1 ± 20%))`.
/// Jitter is applied *before* the cap so the cap is a hard upper bound.
public struct Backoff: Sendable {
    public let base: Duration
    public let cap: Duration
    /// Returns a value in [-1, 1]; scaled by `jitterFraction`.
    let jitter: @Sendable () -> Double
    static let jitterFraction = 0.2
    public private(set) var attempt = 0

    public init(base: Duration = .seconds(1), cap: Duration = .seconds(30)) {
        self.init(base: base, cap: cap, jitter: { Double.random(in: -1...1) })
    }

    init(base: Duration, cap: Duration, jitter: @escaping @Sendable () -> Double) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    /// Delay before the next attempt; advances the attempt counter.
    public mutating func nextDelay() -> Duration {
        let exponent = min(attempt, 20)
        attempt += 1
        let factor = 1 + Self.jitterFraction * max(-1, min(1, jitter()))
        let raw = base * Double(1 << exponent) * factor
        return min(raw, cap)
    }

    public mutating func reset() { attempt = 0 }
}
