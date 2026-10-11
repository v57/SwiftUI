#if os(Windows)
import Foundation
import CSwiftUIWinUI
import _SwiftUICore

enum WinUIText {
    /// The Fluent type ramp (Segoe UI Variable) for SwiftUI's text styles: large title ≈ Title,
    /// title2 ≈ Subtitle, title3 ≈ Body Large, headline ≈ Body Strong, body ≈ Body, caption ≈
    /// Caption.
    static func styleMetrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (28, .semibold)
        case .title: (24, .semibold)
        case .title2: (20, .semibold)
        case .title3: (18, .regular)
        case .headline: (14, .semibold)
        case .subheadline: (13, .regular)
        case .body: (14, .regular)
        case .callout: (13, .regular)
        case .footnote: (12, .regular)
        case .caption: (12, .regular)
        case .caption2: (11, .regular)
        }
    }

    static func install() {
        Font.platformStyleMetrics = { styleMetrics($0) }
        Font.platformControlFont = { size in
            switch size {
            case .mini: .system(size: 11)
            case .small: .system(size: 12)
            default: nil
            }
        }
    }

    /// SwiftUI weight → CSS/DirectWrite font weight (100…900).
    static func cssWeight(_ weight: Font.Weight) -> Int32 {
        switch weight.value {
        case ..<(-0.7): 100
        case ..<(-0.5): 200
        case ..<(-0.2): 300
        case ..<0.1: 400
        case ..<0.27: 500
        case ..<0.35: 600
        case ..<0.5: 700
        case ..<0.6: 800
        default: 900
        }
    }
}

/// Native control metrics, measured once by the host from real WinUI controls
/// (`platform(controlMetrics)`).
@MainActor
enum WinUIControls {
    struct Native {
        var checkbox = CGSize(width: 20, height: 20)
        var radio = CGSize(width: 20, height: 20)
        var switchSize = CGSize(width: 40, height: 20)
        var sliderHeight: CGFloat = 32
        /// TextBox padding (top, leading, bottom, trailing).
        var fieldPadding = EdgeInsets(top: 5, leading: 10, bottom: 6, trailing: 6)
        var fieldHeight: CGFloat = 32
    }

    private static var native: Native?

    static func load(_ host: sui_ref) -> Native {
        if let native { return native }
        var result = Native()
        if let reply = WinUIPlatform.call(host, .controlMetrics, nil) {
            let values = reply.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            if values.count >= 12 {
                result.checkbox = CGSize(width: values[0], height: values[1])
                result.radio = CGSize(width: values[2], height: values[3])
                result.switchSize = CGSize(width: values[4], height: values[5])
                result.sliderHeight = values[6]
                result.fieldPadding = EdgeInsets(top: values[7], leading: values[8], bottom: values[9], trailing: values[10])
                result.fieldHeight = values[11]
            }
        }
        native = result
        return result
    }

    /// Fluent button heights per control size (WinUI's standard button is 32 tall, 11 side padding).
    static let buttonSizes: [ControlSize: ControlMetrics.SizeVariant] = [
        .mini: .init(height: 20, horizontalInset: 6),
        .small: .init(height: 24, horizontalInset: 8),
        .regular: .init(height: 32, horizontalInset: 11),
        .large: .init(height: 40, horizontalInset: 14),
        .extraLarge: .init(height: 48, horizontalInset: 18),
    ]

    static func metrics(_ control: ControlKind, host: sui_ref) -> ControlMetrics {
        let native = load(host)
        switch control {
        case .button(let style):
            switch style {
            case .plain, .borderless, .link: return ControlMetrics()
            default:
                var metrics = ControlMetrics(contentInsets: EdgeInsets(top: 5, leading: 11, bottom: 6, trailing: 11), minSize: CGSize(width: 0, height: 32))
                metrics.sizeTable = buttonSizes
                return metrics
            }
        case .checkbox:
            // Radio groups use the native radio button's size (it doesn't shrink to SwiftUI's 14 × 14).
            var metrics = ControlMetrics(minSize: native.checkbox)
            metrics.radioSize = native.radio
            return metrics
        case .switch:
            // Grouped forms' compact switches stay native size (WinUI has no mini switch).
            var metrics = ControlMetrics(minSize: native.switchSize)
            metrics.compactSize = native.switchSize
            return metrics
        case .textField(let style):
            switch style {
            case .plain: return ControlMetrics(contentInsets: EdgeInsets(), idealWidth: 120)
            default: return ControlMetrics(contentInsets: native.fieldPadding, minSize: CGSize(width: 0, height: native.fieldHeight), idealWidth: 120)
            }
        case .slider: return ControlMetrics(minSize: CGSize(width: 0, height: native.sliderHeight), idealWidth: 0)
        case let .datePicker(date, time, style):
            if style == .graphical { return ControlMetrics(minSize: CGSize(width: 300, height: 340)) }
            return ControlMetrics(minSize: CGSize(width: date && time ? 220 : 120, height: 32))
        }
    }
}

@MainActor
enum WinUIImages {
    private static var sizes: [String: CGSize?] = [:]

    /// Size (epx) of a named image (`Assets/<name>.png|jpg|...` next to the host), nil if missing.
    static func size(named name: String, host: sui_ref) -> CGSize? {
        if let cached = sizes[name] { return cached }
        var size: CGSize?
        if let reply = WinUIPlatform.call(host, .imageSize, name) {
            let values = reply.split(separator: ",").compactMap { Double($0) }
            if values.count == 2 { size = CGSize(width: values[0], height: values[1]) }
        }
        sizes[name] = size
        return size
    }
}

/// Host debug output (the host writes it to its console / debugger).
public enum WinUILog {
    public static func info(_ message: String) { log(4, message) }
    public static func warning(_ message: String) { log(5, message) }
    public static func error(_ message: String) { log(6, message) }

    static func log(_ level: Int32, _ message: String) { sui_log(level, message) }
}

/// Per-phase timing (enabled with the SWIFTUI_PERF environment variable): logged once per second.
enum WinUIPerf {
    enum Phase: Int, CaseIterable { case update, apply, measureText, frame }

    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) private static var totals = [Double](repeating: 0, count: Phase.allCases.count)
    nonisolated(unsafe) private static var counts = [Int](repeating: 0, count: Phase.allCases.count)
    nonisolated(unsafe) private static var windowStart = 0.0

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    @inline(__always)
    static func measure<R>(_ phase: Phase, _ body: () -> R) -> R {
        guard enabled else { return body() }
        let start = now()
        let result = body()
        let end = now()
        totals[phase.rawValue] += end - start
        counts[phase.rawValue] += 1
        if end - windowStart > 1 {
            if windowStart > 0 {
                let parts = Phase.allCases.map { "\($0)=\(counts[$0.rawValue])/\(String(format: "%.1f", totals[$0.rawValue] * 1000))ms" }
                WinUILog.info("perf " + parts.joined(separator: " "))
            }
            windowStart = end
            totals = totals.map { _ in 0 }
            counts = counts.map { _ in 0 }
        }
        return result
    }
}
#endif
