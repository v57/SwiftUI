import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Measures text the way the platform lays it out, outside a view: for grids of fixed cells (a terminal's
/// columns) that need a glyph's advance before laying anything out. AppKit's `NSString.size(withAttributes:)`
/// has no portable counterpart; this asks the backend of the windows on screen.
///
/// ```swift
/// let w = TextMeasurer.measure(Text("W").font(.system(size: 13, design: .monospaced)))
/// let cellWidth = ceil(w?.width ?? 8)
/// ```
@MainActor
public enum TextMeasurer {
    /// What `measure` found: the unrounded width of the text on one line, its height, and the distance from its
    /// top to its first baseline.
    public struct Measurement: Equatable, Sendable {
        public var width: CGFloat
        public var height: CGFloat
        public var baseline: CGFloat

        public init(width: CGFloat, height: CGFloat, baseline: CGFloat) {
            self.width = width
            self.height = height
            self.baseline = baseline
        }
    }

    weak static var backend: (any RenderBackend)?

    /// `text` measured on one line in `environment`; nil until a window is up (no backend to ask yet).
    public static func measure(_ text: Text, in environment: EnvironmentValues = EnvironmentValues()) -> Measurement? {
        guard let backend else { return nil }
        var resolved = text.resolve(in: environment)
        resolved.lineLimit = 1
        let size = backend.measureText(resolved, proposal: .unspecified)
        return Measurement(
            width: backend.unroundedTextWidth(resolved), height: size.height, baseline: backend.firstBaseline(of: resolved))
    }
}
