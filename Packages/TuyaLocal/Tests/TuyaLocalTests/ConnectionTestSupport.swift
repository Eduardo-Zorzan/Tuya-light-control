import Clocks
import Foundation

@testable import TuyaLocal

/// Collects everything a stream emits, from a background task.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<T>) {
        task = Task { [weak self] in
            for await item in stream { self?.lock.withLock { self?._items.append(item) } }
        }
    }
    var items: [T] { lock.withLock { _items } }
    func stop() { task?.cancel() }
}

/// Status without the retry timestamps, for order assertions.
enum StatusKind: Equatable {
    case idle, connecting, connected, offline, error(ConnectionFailure)
    init(_ s: ConnectionStatus) {
        switch s {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .offline: self = .offline
        case .error(let f, _): self = .error(f)
        }
    }
}

/// Lets real network I/O and actor hops settle between virtual-clock steps.
func settle(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }

func makeConfig(_ device: FakeTuyaDevice, key: String = "0123456789abcdef", version: TuyaVersion? = nil, id: String = "devid0123456789")
    -> DeviceConfiguration
{
    DeviceConfiguration(deviceID: id, host: "127.0.0.1", port: device.port, localKey: key, version: version ?? device.version)
}

/// Short real-time timings for tests that run on the real clock.
func fastTiming() -> ConnectionTiming {
    var t = ConnectionTiming()
    t.responseTimeout = .milliseconds(300)
    t.connectTimeout = .seconds(2)
    return t
}
