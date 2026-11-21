import Darwin
import Dispatch
import Foundation

/// What `TuyaDiscovery.start()` managed to bind.
public struct DiscoveryStatus: Sendable, Equatable {
    public var boundPorts: [UInt16] = []
    /// Ports that could not be bound, with the `errno` text (e.g. "Address already in use").
    public var failedPorts: [UInt16: String] = [:]
    /// True when no port could be bound: discovery cannot work (the rest of the app still can).
    public var isUnavailable: Bool { boundPorts.isEmpty }
}

/// Listens for Tuya UDP discovery broadcasts and publishes the announced devices.
///
/// Uses BSD datagram sockets with `SO_REUSEADDR`/`SO_REUSEPORT` so it coexists with other
/// listeners (e.g. Home Assistant, tinytuya). Binding failures never crash: they are logged and
/// reflected in `status` (`isUnavailable`), and the stream simply stays quiet.
public final class TuyaDiscovery: @unchecked Sendable {
    public static let defaultPorts: [UInt16] = [6666, 6667, 7000]

    public let devices: AsyncStream<DiscoveredDevice>
    private let continuation: AsyncStream<DiscoveredDevice>.Continuation
    private let ports: [UInt16]
    private let queue = DispatchQueue(label: "tuya.discovery")
    private let lock = NSLock()
    private var sources: [DispatchSourceRead] = []
    private var _status = DiscoveryStatus()

    public init(ports: [UInt16] = TuyaDiscovery.defaultPorts) {
        self.ports = ports
        (devices, continuation) = AsyncStream.makeStream(of: DiscoveredDevice.self, bufferingPolicy: .bufferingNewest(64))
    }

    public var status: DiscoveryStatus { lock.withLock { _status } }

    /// Binds the listeners. Safe to call once; returns the resulting status.
    @discardableResult
    public func start() -> DiscoveryStatus {
        var result = DiscoveryStatus()
        var newSources: [DispatchSourceRead] = []
        for port in ports {
            switch Self.bindSocket(port: port) {
            case .success(let fd):
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.drain(fd) }
                source.setCancelHandler { close(fd) }
                source.resume()
                newSources.append(source)
                result.boundPorts.append(port)
            case .failure(let failure):
                result.failedPorts[port] = failure.message
                Log.error(.discovery, "discovery port unavailable", address: "udp/\(port)", error: failure)
            }
        }
        lock.withLock {
            sources = newSources
            _status = result
        }
        if result.isUnavailable { Log.error(.discovery, "discovery unavailable: no port could be bound") }
        return result
    }

    public func stop() {
        let toCancel = lock.withLock { () -> [DispatchSourceRead] in
            let s = sources
            sources = []
            return s
        }
        toCancel.forEach { $0.cancel() }
        continuation.finish()
    }

    deinit { stop() }

    // MARK: Socket plumbing

    struct BindFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func bindSocket(port: UInt16) -> Result<Int32, BindFailure> {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return .failure(BindFailure(message: String(cString: strerror(errno)))) }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, size)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            return .failure(BindFailure(message: message))
        }
        return .success(fd)
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength)
                }
            }
            if n <= 0 { return }  // EAGAIN: drained
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = sender.sin_addr
            inet_ntop(AF_INET, &inAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(decoding: ipBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let device = DiscoveryDecoder.decode(Data(buffer[0..<n]), senderIP: senderIP) {
                continuation.yield(device)
            }
        }
    }
}
