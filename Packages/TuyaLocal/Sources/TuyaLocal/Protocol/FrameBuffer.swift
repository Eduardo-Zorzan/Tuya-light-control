import Foundation

/// Accumulates TCP bytes and yields complete raw frames (stream reassembly).
public struct FrameBuffer: Sendable {
    private var data = Data()
    public init() {}

    public mutating func append(_ bytes: Data) { data.append(bytes) }

    /// Returns the next complete frame, or `nil` if more bytes are needed.
    /// Throws on a corrupt prefix / absurd length (the stream is desynchronized).
    public mutating func nextFrame() throws -> Data? {
        guard let length = try TuyaCodec.frameLength(in: data), data.count >= length else { return nil }
        let frame = Data(data.prefix(length))
        data = Data(data.dropFirst(length))
        return frame
    }
}
