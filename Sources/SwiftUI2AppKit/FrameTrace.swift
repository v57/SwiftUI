#if canImport(AppKit)
import AppKit

/// Opt-in timing trace (`SWIFTUI2_TRACE_FRAMES=/path/to/log`, or `touch /tmp/swiftui2-trace-frames`
/// to log to /tmp/swiftui2-frames.log): pointer events, graph updates
/// and animation frames with timestamps, to diagnose interaction latency in real apps.
@MainActor
enum FrameTrace {
    static let handle: FileHandle? = {
        // Also on when the marker file exists (apps launched from Xcode don't see shell variables).
        let marker = "/tmp/swiftui2-trace-frames"
        guard let path = ProcessInfo.processInfo.environment["SWIFTUI2_TRACE_FRAMES"]
            ?? (FileManager.default.fileExists(atPath: marker) ? "/tmp/swiftui2-frames.log" : nil) else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static var isEnabled: Bool { handle != nil }

    static func log(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data(String(format: "%.4f ", CACurrentMediaTime()).appending(message()).appending("\n").utf8))
    }

    /// Runs `body`, logging its duration.
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        log("\(label) \(String(format: "%.2fms", (CACurrentMediaTime() - start) * 1000))")
        return result
    }
}
/// SwiftUI2 animates everything itself (frame by frame); Core Animation's implicit layer actions
/// (0.25 s on every property change of standalone sublayers) would make layers trail behind.
@MainActor
func withoutImplicitAnimations<T>(_ body: () -> T) -> T {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    return body()
}
#endif
