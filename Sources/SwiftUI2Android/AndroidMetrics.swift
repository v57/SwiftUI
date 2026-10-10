#if os(Android)
import Foundation
import CSwiftUI2Android
import SwiftUI2Core

enum AndroidText {
    /// Material 3 type scale (sp) for SwiftUI's text styles, by role: large title ≈ headline
    /// large, title ≈ headline medium, title2 ≈ title large, headline ≈ title medium, body ≈ body
    /// large, footnote/caption ≈ body small / label medium.
    static func styleMetrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: (32, .regular)
        case .title: (28, .regular)
        case .title2: (22, .regular)
        case .title3: (20, .regular)
        case .headline: (16, .semibold)
        case .subheadline: (14, .regular)
        case .body: (16, .regular)
        case .callout: (15, .regular)
        case .footnote: (13, .regular)
        case .caption: (12, .regular)
        case .caption2: (11, .regular)
        }
    }

    static func install() {
        Font.platformStyleMetrics = { styleMetrics($0) }
    }

    /// SwiftUI weight → CSS/Android font weight (100…900).
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

/// Native widget metrics, measured once by the host from real widgets (`platform(controlMetrics)`).
@MainActor
enum AndroidControls {
    struct Native {
        var checkbox = CGSize(width: 32, height: 32)
        var radio = CGSize(width: 32, height: 32)
        var switchSize = CGSize(width: 52, height: 32)
        var sliderHeight: CGFloat = 32
        /// EditText padding (top, start, bottom, end).
        var fieldPadding = EdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 4)
    }

    private static var native: Native?

    static func load(_ host: sui_ref) -> Native {
        if let native { return native }
        var result = Native()
        if let reply = AndroidPlatform.call(host, .controlMetrics, nil) {
            let values = reply.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            if values.count >= 11 {
                result.checkbox = CGSize(width: values[0], height: values[1])
                result.radio = CGSize(width: values[2], height: values[3])
                result.switchSize = CGSize(width: values[4], height: values[5])
                result.sliderHeight = values[6]
                result.fieldPadding = EdgeInsets(top: values[7], leading: values[8], bottom: values[9], trailing: values[10])
            }
        }
        native = result
        return result
    }

    static func metrics(_ control: ControlKind, host: sui_ref) -> ControlMetrics {
        let native = load(host)
        switch control {
        case .button(let style):
            switch style {
            case .plain, .borderless, .link: return ControlMetrics()
            // Material buttons: 40dp tall, 16dp side padding (24 for filled M3; denser here).
            default: return ControlMetrics(contentInsets: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16), minSize: CGSize(width: 0, height: 40))
            }
        case .checkbox: return ControlMetrics(minSize: native.checkbox)
        case .switch: return ControlMetrics(minSize: native.switchSize)
        case .textField(let style):
            switch style {
            case .plain: return ControlMetrics(contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0), idealWidth: 120)
            default: return ControlMetrics(contentInsets: native.fieldPadding, minSize: CGSize(width: 0, height: 48), idealWidth: 120)
            }
        case .slider: return ControlMetrics(minSize: CGSize(width: 0, height: native.sliderHeight), idealWidth: 0)
        case let .datePicker(date, time, style):
            if style == .graphical { return ControlMetrics(minSize: CGSize(width: 320, height: 360)) }
            return ControlMetrics(minSize: CGSize(width: date && time ? 200 : 110, height: 40))
        }
    }
}

@MainActor
enum AndroidImages {
    private static var sizes: [String: CGSize?] = [:]

    /// Size (dp) of a drawable / asset image, nil if missing.
    static func size(named name: String, host: sui_ref) -> CGSize? {
        if let cached = sizes[name] { return cached }
        var size: CGSize?
        if let reply = AndroidPlatform.call(host, .imageSize, name) {
            let values = reply.split(separator: ",").compactMap { Double($0) }
            if values.count == 2 { size = CGSize(width: values[0], height: values[1]) }
        }
        sizes[name] = size
        return size
    }
}

/// Per-phase timing (enabled with `setprop debug.swiftui2.perf 1` + app restart): logged once
/// per second to logcat.
enum AndroidPerf {
    enum Phase: Int, CaseIterable { case update, apply, measureText, frame }

    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) private static var totals = [Double](repeating: 0, count: Phase.allCases.count)
    nonisolated(unsafe) private static var counts = [Int](repeating: 0, count: Phase.allCases.count)
    nonisolated(unsafe) private static var windowStart = 0.0

    static func now() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_MONOTONIC, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

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
                sui_log(4, "perf " + parts.joined(separator: " "))
            }
            windowStart = end
            totals = totals.map { _ in 0 }
            counts = counts.map { _ in 0 }
        }
        return result
    }
}
#endif
