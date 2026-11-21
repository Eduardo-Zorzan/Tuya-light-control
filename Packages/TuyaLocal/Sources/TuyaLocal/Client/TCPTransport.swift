import Foundation
import Network

/// Thin `NWConnection` wrapper: connect, send bytes, and a stream of reassembled raw frames.
final class TCPTransport: @unchecked Sendable {
    let frames: AsyncThrowingStream<Data, Error>
    private let framesContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tuya.transport")
    private var buffer = FrameBuffer()  // only touched on `queue`
    private var finished = false  // only touched on `queue`

    init(host: String, port: UInt16, keepalive: Bool = true) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        (frames, framesContinuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
    }

    /// Waits until the TCP connection is established. Fails fast on refusal / permission denial.
    /// The caller is responsible for applying the connect timeout (cancel this task).
    func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once(cont)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if once.resume(.success(())) {
                            self.installRuntimeStateHandler()
                            self.receiveNext()
                        }
                    case .failed(let error):
                        once.resume(.failure(TuyaError.classify(error)))
                    case .waiting(let error):
                        // `waiting` is transient for most errors; refusal and permission denial are not.
                        let mapped = TuyaError.classify(error)
                        if mapped == .connectionRefused || mapped == .localNetworkDenied {
                            if once.resume(.failure(mapped)) { self.connection.cancel() }
                        }
                    case .cancelled:
                        once.resume(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func installRuntimeStateHandler() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error): self.finish(TuyaError.classify(error))
            case .cancelled: self.finish(TuyaError.connectionClosed)
            default: break
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: TuyaError.classify(error)) } else { cont.resume() }
                })
        }
    }

    func cancel() {
        connection.cancel()
        queue.async { self.finish(TuyaError.connectionClosed) }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    while let frame = try self.buffer.nextFrame() { self.framesContinuation.yield(frame) }
                } catch {
                    self.finish(error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.finish(TuyaError.classify(error))
                return
            }
            if isComplete {
                self.finish(TuyaError.connectionClosed)
                return
            }
            self.receiveNext()
        }
    }

    private func finish(_ error: Error) {
        guard !finished else { return }
        finished = true
        framesContinuation.finish(throwing: error)
    }
}

/// Resumes a continuation at most once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }

    @discardableResult
    func resume(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return false }
        c.resume(with: result)
        return true
    }
}

extension TuyaError {
    /// Maps Network.framework errors to the typed errors this package exposes.
    static func classify(_ error: NWError) -> TuyaError {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .connectionRefused
            case .EPERM, .EACCES: return .localNetworkDenied
            case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return .timeout
            case .ECONNRESET, .EPIPE, .ENOTCONN: return .connectionClosed
            default: return .protocol("posix \(code.rawValue)")
            }
        case .dns: return .timeout
        case .tls: return .protocol("tls")
        default: return .protocol("network error")
        }
    }
}
