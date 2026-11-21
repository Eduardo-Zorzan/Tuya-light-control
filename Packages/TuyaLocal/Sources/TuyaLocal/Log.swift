import Foundation
import os

public enum LogCategory: String, Sendable {
    case connection, discovery, cloud, ui
}

/// Unified-logging helper that cannot be handed secrets: messages are compile-time constants,
/// and the only dynamic values are a device id (logged `.private`), a network address and an error.
/// Local keys, cloud secrets and payload bytes have no way in.
public enum Log {
    private static let subsystem = "com.catlight.TuyaLocal"
    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: [LogCategory.connection, .discovery, .cloud, .ui].map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        })

    public static func debug(
        _ category: LogCategory, _ message: StaticString, device: String? = nil, address: String? = nil, error: Error? = nil
    ) {
        emit(.debug, category, message, device, address, error)
    }

    public static func info(
        _ category: LogCategory, _ message: StaticString, device: String? = nil, address: String? = nil, error: Error? = nil
    ) {
        emit(.info, category, message, device, address, error)
    }

    public static func error(
        _ category: LogCategory, _ message: StaticString, device: String? = nil, address: String? = nil, error: Error? = nil
    ) {
        emit(.error, category, message, device, address, error)
    }

    private static func emit(
        _ level: OSLogType, _ category: LogCategory, _ message: StaticString, _ device: String?, _ address: String?, _ error: Error?
    ) {
        guard let logger = loggers[category] else { return }
        let d = device ?? "-"
        let a = address ?? "-"
        let e = error.map { String(describing: $0) } ?? "-"
        // `message` is a StaticString so it is always public; dynamic parts are explicit.
        logger.log(
            level: level,
            "\(message.description, privacy: .public) device=\(d, privacy: .private) addr=\(a, privacy: .public) err=\(e, privacy: .public)"
        )
    }
}
