import Foundation
import TuyaLocal

@testable import catLight

/// Records every call the app makes to the connection layer.
actor FakeManager: DeviceControlling {
    nonisolated let updates: AsyncStream<DeviceUpdate>
    private let continuation: AsyncStream<DeviceUpdate>.Continuation

    private(set) var added: [DeviceConfiguration] = []
    private(set) var removed: [String] = []
    private(set) var patches: [(patch: DPMap, ids: [String])] = []
    private(set) var addressUpdates: [(String, String)] = []
    private(set) var keyUpdates: [(String, String)] = []
    private(set) var reconnectAllCount = 0
    private(set) var refreshAllCount = 0
    private(set) var shutdownCount = 0

    init() { (updates, continuation) = AsyncStream.makeStream(of: DeviceUpdate.self, bufferingPolicy: .unbounded) }

    func emit(_ update: DeviceUpdate) { continuation.yield(update) }

    func add(_ configuration: DeviceConfiguration) { added.append(configuration) }
    func remove(deviceID: String) { removed.append(deviceID) }
    func setDesired(_ patch: DPMap, for ids: [String]) { patches.append((patch, ids)) }
    func updateAddress(deviceID: String, host: String, version: TuyaVersion?) { addressUpdates.append((deviceID, host)) }
    func updateKey(deviceID: String, localKey: String) { keyUpdates.append((deviceID, localKey)) }
    func reconnectAll() { reconnectAllCount += 1 }
    func refreshAll() { refreshAllCount += 1 }
    func shutdown() { shutdownCount += 1 }
}
