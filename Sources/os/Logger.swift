// os stand-in (Linux, Windows, Android): unified logging's Swift API (`Logger`, `OSLog`, `os_log`) writing to
// standard error (and the debugger on Windows), plus `OSAllocatedUnfairLock`. Private values are redacted as on
// Apple platforms unless the build is DEBUG.
import Foundation

#if os(Windows)
import WinSDK
#endif

public enum OSLogType: UInt8, Sendable {
    case `default` = 0, info = 1, debug = 2, error = 16, fault = 17
}

public struct OSLogPrivacy: Sendable, Equatable {
    let isPublic: Bool
    public static let `public` = OSLogPrivacy(isPublic: true)
    public static let `private` = OSLogPrivacy(isPublic: false)
    public static let sensitive = OSLogPrivacy(isPublic: false)
    public static let auto = OSLogPrivacy(isPublic: false)
    public static func `private`(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { .private }
    public static func auto(mask: OSLogPrivacy.Mask) -> OSLogPrivacy { .auto }
    public enum Mask: Sendable { case hash, none }
}

public struct OSLogIntegerFormatting: Sendable {
    public static let decimal = OSLogIntegerFormatting()
    public static let hex = OSLogIntegerFormatting()
    public static func decimal(explicitPositiveSign: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting { .init() }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false, minDigits: Int = 0) -> OSLogIntegerFormatting { .init() }
}

public struct OSLogFloatFormatting: Sendable {
    public static let fixed = OSLogFloatFormatting()
    public static func fixed(precision: Int, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting { .init() }
}

public struct OSLogStringAlignment: Sendable {
    public static let none = OSLogStringAlignment()
    public static func left(columns: Int) -> OSLogStringAlignment { .init() }
    public static func right(columns: Int) -> OSLogStringAlignment { .init() }
}

/// A log message: literal text and interpolated values with their privacy.
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { text += literal }

        mutating func append(_ value: @autoclosure () -> String, _ privacy: OSLogPrivacy) {
            #if DEBUG
            text += value()
            #else
            text += privacy.isPublic ? value() : "<private>"
            #endif
        }

        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> String, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
            append(value(), privacy)
        }
        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: @autoclosure @escaping () -> T, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
            append(value().description, privacy)
        }
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: @autoclosure @escaping () -> T, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .public) {
            append(String(value()), privacy)
        }
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Double, format: OSLogFloatFormatting = .fixed, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .public) {
            append(String(value()), privacy)
        }
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Bool, privacy: OSLogPrivacy = .public) {
            append(value() ? "true" : "false", privacy)
        }
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> any Error, privacy: OSLogPrivacy = .auto) {
            append(String(describing: value()), privacy)
        }
        public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Any.Type, privacy: OSLogPrivacy = .auto) {
            append(String(describing: value()), privacy)
        }
        public mutating func appendInterpolation<T>(_ value: @autoclosure @escaping () -> T?, privacy: OSLogPrivacy = .auto) {
            append(value().map { String(describing: $0) } ?? "nil", privacy)
        }
    }

    let text: String

    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

/// Where log messages go: standard error and, on Windows, the debugger.
enum LogSink {
    static func write(subsystem: String, category: String, type: OSLogType, _ message: String) {
        let level: String = switch type {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        case .fault: "fault"
        default: "notice"
        }
        let line = "[\(subsystem)\(category.isEmpty ? "" : ":\(category)")] \(level): \(message)\n"
        fputs(line, stderr)
        #if os(Windows)
        line.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
        #endif
    }
}

public final class OSLog: @unchecked Sendable {
    let subsystem: String
    let category: String

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    public static let `default` = OSLog(subsystem: "", category: "")
    public static let disabled = OSLog(subsystem: "", category: "")
    public var signpostsEnabled: Bool { false }
}

public struct Logger: @unchecked Sendable {
    let log: OSLog

    public init() { log = .default }
    public init(subsystem: String, category: String) { log = OSLog(subsystem: subsystem, category: category) }
    public init(_ log: OSLog) { self.log = log }

    public func log(_ message: OSLogMessage) { write(.default, message) }
    public func log(level: OSLogType, _ message: OSLogMessage) { write(level, message) }
    public func trace(_ message: OSLogMessage) { write(.debug, message) }
    public func debug(_ message: OSLogMessage) { write(.debug, message) }
    public func info(_ message: OSLogMessage) { write(.info, message) }
    public func notice(_ message: OSLogMessage) { write(.default, message) }
    public func warning(_ message: OSLogMessage) { write(.error, message) }
    public func error(_ message: OSLogMessage) { write(.error, message) }
    public func critical(_ message: OSLogMessage) { write(.fault, message) }
    public func fault(_ message: OSLogMessage) { write(.fault, message) }

    private func write(_ type: OSLogType, _ message: OSLogMessage) {
        #if !DEBUG
        if type == .debug { return }
        #endif
        LogSink.write(subsystem: log.subsystem, category: log.category, type: type, message.text)
    }
}

public func os_log(_ type: OSLogType, log: OSLog = .default, _ message: OSLogMessage) {
    LogSink.write(subsystem: log.subsystem, category: log.category, type: type, message.text)
}

public func os_log(_ message: OSLogMessage, log: OSLog = .default, type: OSLogType = .default) {
    LogSink.write(subsystem: log.subsystem, category: log.category, type: type, message.text)
}

/// Signposts (Instruments intervals): accepted and dropped.
public struct OSSignposter: Sendable {
    public struct IntervalState: Sendable {}
    public init() {}
    public init(subsystem: String, category: String) {}
    public init(logger: Logger) {}
    public static let disabled = OSSignposter()
    public var isEnabled: Bool { false }
    public func makeSignpostID() -> OSSignpostID { OSSignpostID() }
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> IntervalState { IntervalState() }
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage) -> IntervalState { IntervalState() }
    public func endInterval(_ name: StaticString, _ state: IntervalState) {}
    public func endInterval(_ name: StaticString, _ state: IntervalState, _ message: OSLogMessage) {}
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive) {}
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage) {}
    public func withIntervalSignpost<T>(_ name: StaticString, id: OSSignpostID = .exclusive, around task: () throws -> T) rethrows -> T { try task() }
}

public struct OSSignpostID: Sendable, Hashable {
    public static let exclusive = OSSignpostID()
    public static let invalid = OSSignpostID()
    public static let null = OSSignpostID()
    public init() {}
}

/// A lock around a value (Apple's `OSAllocatedUnfairLock`), on `NSLock`.
public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private final class Box {
        let lock = NSLock()
        var state: State
        init(_ state: State) { self.state = state }
    }

    private let box: Box

    public init(initialState: State) { box = Box(initialState) }

    public func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R {
        box.lock.lock()
        defer { box.lock.unlock() }
        return try body(&box.state)
    }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        box.lock.lock()
        defer { box.lock.unlock() }
        return try body(&box.state)
    }

    public func lock() { box.lock.lock() }
    public func unlock() { box.lock.unlock() }
}

extension OSAllocatedUnfairLock where State == Void {
    public init() { self.init(initialState: ()) }

    public func withLock<R>(_ body: @Sendable () throws -> R) rethrows -> R {
        box.lock.lock()
        defer { box.lock.unlock() }
        return try body()
    }
}
