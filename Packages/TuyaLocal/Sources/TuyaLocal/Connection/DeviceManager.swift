import Foundation

/// Update from any managed light, tagged with its device id.
public enum DeviceUpdate: Sendable, Equatable {
    case status(deviceID: String, ConnectionStatus)
    case state(deviceID: String, ReportedState)
    case event(deviceID: String, ConnectionEvent)
}

/// Owns one `DeviceConnection` per registered light.
///
/// Connections are independent actors: "all lights" fans a patch out to each without waiting on the
/// others, so an offline light never delays the rest.
public actor DeviceManager {
    /// Merged updates of every light (consumed by the app model).
    public nonisolated let updates: AsyncStream<DeviceUpdate>
    private let updatesContinuation: AsyncStream<DeviceUpdate>.Continuation

    private let makeConnection: @Sendable (DeviceConfiguration) -> DeviceConnection
    private var connections: [String: DeviceConnection] = [:]
    private var forwarders: [String: [Task<Void, Never>]] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var isShutdown = false

    public init<C: Clock<Duration>>(
        timing: ConnectionTiming = ConnectionTiming(),
        clock: C = ContinuousClock(),
        connector: @escaping DeviceConnector = DefaultConnector.connect
    ) {
        self.makeConnection = { DeviceConnection(configuration: $0, timing: timing, clock: clock, connector: connector) }
        (updates, updatesContinuation) = AsyncStream.makeStream(of: DeviceUpdate.self, bufferingPolicy: .unbounded)
    }

    public var deviceIDs: [String] { connections.keys.sorted() }

    /// Registers a light and starts connecting. Replaces an existing light with the same id.
    public func add(_ configuration: DeviceConfiguration) async {
        guard !isShutdown else { return }
        if connections[configuration.deviceID] != nil { await remove(deviceID: configuration.deviceID) }
        let id = configuration.deviceID
        let connection = makeConnection(configuration)
        connections[id] = connection
        let out = updatesContinuation
        forwarders[id] = [
            Task { for await s in connection.statuses { out.yield(.status(deviceID: id, s)) } },
            Task { for await s in connection.states { out.yield(.state(deviceID: id, s)) } },
            Task { for await e in connection.events { out.yield(.event(deviceID: id, e)) } },
        ]
        await connection.start()
    }

    /// Stops and forgets a light.
    public func remove(deviceID: String) async {
        guard let connection = connections.removeValue(forKey: deviceID) else { return }
        await connection.shutdown()
        // Let the forwarders drain what the connection emitted before finishing, then stop them.
        let tasks = forwarders.removeValue(forKey: deviceID) ?? []
        for t in tasks { await t.value }
    }

    public func connection(for deviceID: String) -> DeviceConnection? { connections[deviceID] }

    /// Applies a datapoint patch to the given lights (all registered lights when `ids` is nil).
    /// Each connection merges it immediately; none waits on another.
    public func setDesired(_ patch: DPMap, for ids: [String]? = nil) async {
        let targets = (ids ?? Array(connections.keys)).compactMap { connections[$0] }
        await withTaskGroup(of: Void.self) { group in
            for c in targets { group.addTask { await c.setDesired(patch) } }
        }
    }

    public func updateAddress(deviceID: String, host: String, version: TuyaVersion? = nil) async {
        await connections[deviceID]?.updateAddress(host, version: version)
    }

    public func updateKey(deviceID: String, localKey: String) async {
        await connections[deviceID]?.updateKey(localKey)
    }

    /// Wake from sleep / network change: reconnect every light immediately.
    public func reconnectAll() async {
        for c in connections.values { await c.reconnectNow() }
    }

    /// Popover opened: reconnect lights that are not connected, refresh those that are.
    public func refreshAll() async {
        for c in connections.values {
            if await c.status.isConnected { await c.refresh() } else { await c.reconnectNow() }
        }
    }

    /// Feeds discovery broadcasts into address/version updates for known lights.
    public func consume(discovery: AsyncStream<DiscoveredDevice>) {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            for await found in discovery {
                await self?.updateAddress(deviceID: found.deviceID, host: found.ip, version: found.version)
            }
        }
    }

    /// Closes every connection without sending any command to the lights.
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        discoveryTask?.cancel()
        for id in Array(connections.keys) { await remove(deviceID: id) }
        updatesContinuation.finish()
    }
}
