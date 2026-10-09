import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Mirrors `SwiftUI.Color`. The `View` conformance lives in ColorView.swift so that `Color` itself
/// stays nonisolated (usable from any context, like SwiftUI's).
public struct Color: Hashable, Sendable, CustomStringConvertible {
    public struct Resolved: Hashable, Sendable {
        public var red: Float
        public var green: Float
        public var blue: Float
        public var opacity: Float

        public init(red: Float, green: Float, blue: Float, opacity: Float = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.opacity = opacity
        }
    }

    indirect enum Storage: Hashable, Sendable {
        case resolved(Resolved)
        case dynamic(light: Resolved, dark: Resolved)
        case accent
        case opacity(Storage, Double)
    }

    let storage: Storage

    init(storage: Storage) { self.storage = storage }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        storage = .resolved(Resolved(red: Float(red), green: Float(green), blue: Float(blue), opacity: Float(opacity)))
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        let h = (hue - floor(hue)) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, opacity: opacity)
    }

    public init(_ resolved: Resolved) { storage = .resolved(resolved) }

    public func opacity(_ opacity: Double) -> Color { Color(storage: .opacity(storage, opacity)) }

    public func resolve(in environment: EnvironmentValues) -> Resolved {
        Self.resolve(storage, environment)
    }

    private static func resolve(_ storage: Storage, _ environment: EnvironmentValues) -> Resolved {
        switch storage {
        case .resolved(let resolved): return resolved
        case let .dynamic(light, dark): return environment.colorScheme == .dark ? dark : light
        case .accent: return (environment.tint ?? .blue).resolve(in: environment)
        case let .opacity(base, opacity):
            var resolved = resolve(base, environment)
            resolved.opacity *= Float(opacity)
            return resolved
        }
    }

    public var description: String {
        switch storage {
        case .resolved(let r): return "Color(\(r.red), \(r.green), \(r.blue), \(r.opacity))"
        default: return "Color(\(storage))"
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Resolved {
        Resolved(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a))
    }

    private static func dynamic(_ light: Resolved, _ dark: Resolved) -> Color { Color(storage: .dynamic(light: light, dark: dark)) }

    // macOS system colors (light / dark).
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let gray = dynamic(rgb(0.557, 0.557, 0.576), rgb(0.557, 0.557, 0.576))
    public static let red = dynamic(rgb(1, 0.231, 0.188), rgb(1, 0.271, 0.227))
    public static let orange = dynamic(rgb(1, 0.584, 0), rgb(1, 0.624, 0.039))
    public static let yellow = dynamic(rgb(1, 0.8, 0), rgb(1, 0.839, 0.039))
    public static let green = dynamic(rgb(0.204, 0.78, 0.349), rgb(0.188, 0.82, 0.345))
    public static let mint = dynamic(rgb(0, 0.78, 0.745), rgb(0.388, 0.902, 0.886))
    public static let teal = dynamic(rgb(0.188, 0.69, 0.78), rgb(0.251, 0.784, 0.878))
    public static let cyan = dynamic(rgb(0.196, 0.678, 0.902), rgb(0.392, 0.824, 1))
    public static let blue = dynamic(rgb(0, 0.478, 1), rgb(0.039, 0.518, 1))
    public static let indigo = dynamic(rgb(0.345, 0.337, 0.839), rgb(0.369, 0.361, 0.902))
    public static let purple = dynamic(rgb(0.686, 0.322, 0.871), rgb(0.749, 0.353, 0.949))
    public static let pink = dynamic(rgb(1, 0.176, 0.333), rgb(1, 0.216, 0.373))
    public static let brown = dynamic(rgb(0.635, 0.518, 0.369), rgb(0.675, 0.557, 0.408))
    public static let primary = dynamic(rgb(0, 0, 0, 0.85), rgb(1, 1, 1, 0.85))
    public static let secondary = dynamic(rgb(0, 0, 0, 0.5), rgb(1, 1, 1, 0.55))
    public static let accentColor = Color(storage: .accent)
    static let separator = dynamic(rgb(0, 0, 0, 0.1), rgb(1, 1, 1, 0.1))
    static let controlBackground = dynamic(rgb(1, 1, 1), rgb(0.118, 0.118, 0.118))
    /// Split view sidebar column (the window background on macOS 26+).
    static let sidebarBackground = dynamic(rgb(0, 0, 0, 0), rgb(1, 1, 1, 0))
    static let listSelection = dynamic(rgb(0, 0, 0, 0.1), rgb(1, 1, 1, 0.12))
    static let listBorder = dynamic(rgb(0, 0, 0, 0.15), rgb(1, 1, 1, 0.3))
    static let splitDivider = dynamic(rgb(0, 0, 0, 0.12), rgb(0, 0, 0, 1))
    static let segmentedTrack = dynamic(rgb(0, 0, 0, 0.06), rgb(1, 1, 1, 0.065))
    static let segmentedSelection = dynamic(rgb(1, 1, 1), rgb(1, 1, 1, 0.33))
}

// MARK: - ShapeStyle

/// Mirrors `SwiftUI.ShapeStyle`. Styles resolve to a color in an environment (gradients and
/// materials are on the roadmap).
public protocol ShapeStyle: Sendable {
    func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint
}

/// A resolved fill: a solid color or a gradient.
public enum ResolvedPaint: Equatable, Sendable {
    case color(Color.Resolved)
    case gradient(ResolvedGradient)

    public var colorValue: Color.Resolved { color }

    var color: Color.Resolved {
        switch self {
        case .color(let color): return color
        case .gradient(let gradient): return gradient.averageColor
        }
    }
}

extension ShapeStyle {
    public func _resolveColor(in environment: EnvironmentValues) -> Color.Resolved {
        _resolvePaint(in: environment).color
    }
}

extension Color: ShapeStyle {
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { .color(resolve(in: environment)) }
}

public struct ForegroundStyle: ShapeStyle, Hashable {
    public init() {}
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        environment.foregroundStyle?._resolvePaint(in: environment) ?? .color(Color.primary.resolve(in: environment))
    }
}

public struct HierarchicalShapeStyle: ShapeStyle, Hashable {
    let level: Int
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        // Relative to the current foreground style (unless that is itself hierarchical).
        var base = Color.primary.resolve(in: environment)
        if let style = environment.foregroundStyle, !(style.base is HierarchicalShapeStyle) {
            base = style._resolveColor(in: environment)
        }
        let factors: [Float] = [1, 0.6, 0.35, 0.2]
        base.opacity *= factors[min(level, factors.count - 1)]
        return .color(base)
    }

    public static let primary = HierarchicalShapeStyle(level: 0)
    public static let secondary = HierarchicalShapeStyle(level: 1)
    public static let tertiary = HierarchicalShapeStyle(level: 2)
    public static let quaternary = HierarchicalShapeStyle(level: 3)
}

public struct TintShapeStyle: ShapeStyle, Hashable {
    public init() {}
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .color((environment.tint ?? .accentColor).resolve(in: environment))
    }
}

public struct SeparatorShapeStyle: ShapeStyle, Hashable {
    public init() {}
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { .color(Color.separator.resolve(in: environment)) }
}

public struct BackgroundStyle: ShapeStyle, Hashable {
    public init() {}
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { .color(Color.controlBackground.resolve(in: environment)) }
}

extension ShapeStyle where Self == SeparatorShapeStyle { public static var separator: SeparatorShapeStyle { .init() } }
extension ShapeStyle where Self == BackgroundStyle { public static var background: BackgroundStyle { .init() } }

public struct AnyShapeStyle: ShapeStyle, Equatable {
    public static func == (lhs: AnyShapeStyle, rhs: AnyShapeStyle) -> Bool { GraphComparison.compareAny(lhs.base, rhs.base) }

    let base: any ShapeStyle
    public init<S: ShapeStyle>(_ style: S) {
        if let any = style as? AnyShapeStyle { base = any.base } else { base = style }
    }
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { base._resolvePaint(in: environment) }
}

extension AnyShapeStyle: _GraphComparable {
    public static func _isIdentical(_ lhs: AnyShapeStyle, _ rhs: AnyShapeStyle) -> Bool {
        GraphComparison.compareAny(lhs.base, rhs.base)
    }
}

extension ShapeStyle where Self == ForegroundStyle {
    public static var foreground: ForegroundStyle { ForegroundStyle() }
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
    public static var quaternary: HierarchicalShapeStyle { .quaternary }
}

extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { TintShapeStyle() }
}

extension ShapeStyle where Self == Color {
    public static var red: Color { Color.red }
    public static var orange: Color { Color.orange }
    public static var yellow: Color { Color.yellow }
    public static var green: Color { Color.green }
    public static var mint: Color { Color.mint }
    public static var teal: Color { Color.teal }
    public static var cyan: Color { Color.cyan }
    public static var blue: Color { Color.blue }
    public static var indigo: Color { Color.indigo }
    public static var purple: Color { Color.purple }
    public static var pink: Color { Color.pink }
    public static var brown: Color { Color.brown }
    public static var white: Color { Color.white }
    public static var gray: Color { Color.gray }
    public static var black: Color { Color.black }
    public static var clear: Color { Color.clear }
}
