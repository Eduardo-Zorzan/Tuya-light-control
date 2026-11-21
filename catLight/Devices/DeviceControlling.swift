import Foundation
import TuyaLocal

/// What the app needs from the connection layer; `DeviceManager` implements it, tests fake it.
protocol DeviceControlling: Sendable {
    var updates: AsyncStream<DeviceUpdate> { get }
    func add(_ configuration: DeviceConfiguration) async
    func remove(deviceID: String) async
    func setDesired(_ patch: DPMap, for ids: [String]) async
    func updateAddress(deviceID: String, host: String, version: TuyaVersion?) async
    func updateKey(deviceID: String, localKey: String) async
    func reconnectAll() async
    func refreshAll() async
    func shutdown() async
}

extension DeviceManager: DeviceControlling {
    func setDesired(_ patch: DPMap, for ids: [String]) async {
        await setDesired(patch, for: Optional(ids))
    }
}
