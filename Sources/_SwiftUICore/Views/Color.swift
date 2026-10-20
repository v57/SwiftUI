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
        case mix(Storage, Storage, Double)
    }

    let storage: Storage

    init(storage: Storage) { self.storage = storage }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        storage = .resolved(Resolved(red: Float(red), green: Float(green), blue: Float(blue), opacity: Float(opacity)))
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public enum RGBColorSpace: Hashable, Sendable { case sRGB, sRGBLinear, displayP3 }

    /// A color in a color space, converted to sRGB (Display P3 colors are mapped, not clipped
    /// beyond the sRGB gamut).
    public init(_ colorSpace: RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func gamma(_ v: Double) -> Double { let c = min(max(v, 0), 1); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        switch colorSpace {
        case .sRGB:
            self.init(red: red, green: green, blue: blue, opacity: opacity)
        case .sRGBLinear:
            self.init(red: gamma(red), green: gamma(green), blue: gamma(blue), opacity: opacity)
        case .displayP3:
            let (r, g, b) = (linear(red), linear(green), linear(blue))
            let sr = 1.2249 * r - 0.2247 * g + 0.0000 * b
            let sg = -0.0420 * r + 1.0419 * g + 0.0000 * b
            let sb = -0.0197 * r - 0.0786 * g + 1.0979 * b
            self.init(red: gamma(sr), green: gamma(sg), blue: gamma(sb), opacity: opacity)
        }
    }

    public init(_ colorSpace: RGBColorSpace, white: Double, opacity: Double = 1) {
        self.init(colorSpace, red: white, green: white, blue: white, opacity: opacity)
    }

    /// A color with separate light and dark appearance values (backends build platform colors).
    public init(_light light: Resolved, dark: Resolved) {
        storage = .dynamic(light: light, dark: dark)
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

    /// A color for each appearance, as AppKit's and UIKit's dynamic system colors are. (A v57/SwiftUI addition for
    /// code without either: Apple's SwiftUI gets there through `Color(nsColor:)` / `Color(uiColor:)`.)
    public init(light: Color, dark: Color) {
        var lightEnvironment = EnvironmentValues()
        lightEnvironment.colorScheme = .light
        var darkEnvironment = EnvironmentValues()
        darkEnvironment.colorScheme = .dark
        storage = .dynamic(light: light.resolve(in: lightEnvironment), dark: dark.resolve(in: darkEnvironment))
    }

    public func opacity(_ opacity: Double) -> Color { Color(storage: .opacity(storage, opacity)) }

    public func resolve(in environment: EnvironmentValues) -> Resolved {
        Self.resolve(storage, environment)
    }

    private static func resolve(_ storage: Storage, _ environment: EnvironmentValues) -> Resolved {
        switch storage {
        case .resolved(let resolved): return resolved
        case let .dynamic(light, dark): return environment.colorScheme == .dark ? dark : light
        case .accent:
            // The system accent is gray in inactive windows (explicit tints keep their color).
            guard let tint = environment.tint else {
                return environment.appearsActive ? Color.blue.resolve(in: environment) : inactiveAccent.resolve(in: environment)
            }
            // A tint made from the accent (`.tint(.accentColor)`) means the system accent underneath.
            var untinted = environment
            untinted.tint = nil
            return tint.resolve(in: untinted)
        case let .opacity(base, opacity):
            var resolved = resolve(base, environment)
            resolved.opacity *= Float(opacity)
            return resolved
        case let .mix(a, b, fraction):
            return .interpolate(resolve(a, environment), resolve(b, environment), fraction)
        }
    }

    public var description: String {
        switch storage {
        case .resolved(let r): return "Color(\(r.red), \(r.green), \(r.blue), \(r.opacity))"
        default: return "Color(\(storage))"
        }
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Resolved {
        Resolved(red: Float(r), green: Float(g), blue: Float(b), opacity: Float(a))
    }

    static func dynamic(_ light: Resolved, _ dark: Resolved) -> Color { Color(storage: .dynamic(light: light, dark: dark)) }

    // macOS system colors (light / dark), as resolved by SwiftUI on macOS 26.
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let gray = dynamic(rgb(0.557, 0.557, 0.576), rgb(0.596, 0.596, 0.616))
    public static let red = dynamic(rgb(1, 0.22, 0.235), rgb(1, 0.259, 0.271))
    public static let orange = dynamic(rgb(1, 0.553, 0.157), rgb(1, 0.573, 0.188))
    public static let yellow = dynamic(rgb(1, 0.8, 0), rgb(1, 0.839, 0))
    public static let green = dynamic(rgb(0.204, 0.78, 0.349), rgb(0.188, 0.82, 0.345))
    public static let mint = dynamic(rgb(0, 0.784, 0.702), rgb(0, 0.855, 0.765))
    public static let teal = dynamic(rgb(0, 0.765, 0.816), rgb(0, 0.824, 0.878))
    public static let cyan = dynamic(rgb(0, 0.753, 0.91), rgb(0.235, 0.827, 0.996))
    public static let blue = dynamic(rgb(0, 0.533, 1), rgb(0, 0.569, 1))
    public static let indigo = dynamic(rgb(0.38, 0.333, 0.961), rgb(0.427, 0.486, 1))
    public static let purple = dynamic(rgb(0.796, 0.188, 0.878), rgb(0.859, 0.204, 0.949))
    public static let pink = dynamic(rgb(1, 0.176, 0.333), rgb(1, 0.216, 0.373))
    public static let brown = dynamic(rgb(0.675, 0.498, 0.369), rgb(0.718, 0.541, 0.4))
    public static let primary = dynamic(rgb(0, 0, 0, 0.85), rgb(1, 1, 1, 0.85))
    public static let secondary = dynamic(rgb(0, 0, 0, 0.5), rgb(1, 1, 1, 0.55))
    public static let accentColor = Color(storage: .accent)
    /// The second of the alternating content background colors (striped rows).
    static let alternatingRow = dynamic(rgb(0, 0, 0, 0.03), rgb(1, 1, 1, 0.05))
    /// Grouped form card, its hairline border and row separators (macOS 26).
    static let formCard = dynamic(rgb(1, 1, 1, 0.6), rgb(0.169, 0.169, 0.169))
    static let formCardBorder = dynamic(rgb(0, 0, 0, 0.08), rgb(0.271, 0.271, 0.271))
    static let formSeparator = dynamic(rgb(0, 0, 0, 0.06), rgb(0.208, 0.208, 0.208))
    /// Link text (link buttons, `Link`) — not the accent: it stays blue in inactive windows.
    public static let link = dynamic(rgb(0.169, 0.4, 0.827), rgb(0.255, 0.584, 1))
    /// The accent color of controls in inactive windows.
    static let inactiveAccent = dynamic(rgb(0.667, 0.667, 0.667), rgb(0.45, 0.45, 0.45))
    static let separator = dynamic(rgb(0, 0, 0, 0.1), rgb(1, 1, 1, 0.1))
    static let controlBackground = dynamic(rgb(1, 1, 1), rgb(0.118, 0.118, 0.118))
    /// Split view sidebar column (the window background on macOS 26+).
    static let sidebarBackground = dynamic(rgb(0, 0, 0, 0), rgb(1, 1, 1, 0))
    static let listSelection = dynamic(rgb(0, 0, 0, 0.1), rgb(1, 1, 1, 0.12))
    /// NSLevelIndicator (continuous capacity) and accessory ring gauges.
    static let levelFill = Color(red: 0.396, green: 0.769, blue: 0.4)
    static let levelTrack = dynamic(rgb(0.898, 0.898, 0.898), rgb(1, 1, 1, 0.15))
    static let levelBorder = dynamic(rgb(0, 0, 0, 0.2), rgb(1, 1, 1, 0.2))
    static let ringTrack = dynamic(rgb(0.68, 0.68, 0.68), rgb(1, 1, 1, 0.3))
    /// Group box (classic): a faint fill with a hairline border.
    static let groupBoxFill = dynamic(rgb(0, 0, 0, 0.016), rgb(1, 1, 1, 0.03))
    static let groupBoxBorder = dynamic(rgb(0, 0, 0, 0.07), rgb(1, 1, 1, 0.1))
    static let listBorder = dynamic(rgb(0, 0, 0, 0.25), rgb(1, 1, 1, 0.3))
    /// The hairline under a list's pinned leading section header.
    static let pinnedHeaderLine = dynamic(rgb(0, 0, 0, 0.2), rgb(1, 1, 1, 0.2))
    /// A sidebar-style list outside a split view (classic design, inactive window).
    static let classicSidebar = dynamic(rgb(0.941, 0.941, 0.941), rgb(0.176, 0.176, 0.176))
    static let searchFieldFill = dynamic(rgb(0, 0, 0, 0.06), rgb(1, 1, 1, 0.1))
    /// Classic search field over the sidebar material / its border elsewhere.
    static let sidebarSearchFill = dynamic(rgb(0, 0, 0, 0.1), rgb(1, 1, 1, 0.1))
    static let searchFieldBorder = dynamic(rgb(0, 0, 0, 0.18), rgb(1, 1, 1, 0.2))
    static let splitDivider = dynamic(rgb(0, 0, 0, 0.12), rgb(0, 0, 0, 1))
    static let segmentedTrack = dynamic(rgb(0, 0, 0, 0.06), rgb(1, 1, 1, 0.065))
    static let segmentedSelection = dynamic(rgb(1, 1, 1), rgb(1, 1, 1, 0.33))
}

// MARK: - ShapeStyle

/// Mirrors `SwiftUI.ShapeStyle`. Styles resolve to a color in an environment (gradients and
/// materials are on the roadmap).
public protocol ShapeStyle: Sendable {
    /// Custom styles resolve to another style for an environment (`func resolve(in:) -> Color`).
    associatedtype Resolved: ShapeStyle = _UnresolvedShapeStyle
    func resolve(in environment: EnvironmentValues) -> Resolved
    func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint
    /// A drop shadow drawn with the shape (`.shadow(_:)` styles).
    func _resolveShadow(in environment: EnvironmentValues) -> ResolvedShadow?
}

extension ShapeStyle {
    public func _resolveShadow(in environment: EnvironmentValues) -> ResolvedShadow? { nil }
}

/// Shadows of shape styles (`.fill(.blue.shadow(.drop(radius: 4)))`).
public struct ShadowStyle: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case drop, inner }
    let kind: Kind
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    public static func drop(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> ShadowStyle {
        ShadowStyle(kind: .drop, color: color, radius: radius, x: x, y: y)
    }

    /// Inner shadows are not drawn (accepted for source compatibility).
    public static func inner(color: Color = Color(white: 0, opacity: 0.55), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> ShadowStyle {
        ShadowStyle(kind: .inner, color: color, radius: radius, x: x, y: y)
    }
}

public struct _ShadowShapeStyle<Base: ShapeStyle>: ShapeStyle {
    let base: Base
    let shadow: ShadowStyle
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { base._resolvePaint(in: environment) }
    public func _resolveShadow(in environment: EnvironmentValues) -> ResolvedShadow? {
        guard shadow.kind == .drop else { return base._resolveShadow(in: environment) }
        return ResolvedShadow(color: shadow.color.resolve(in: environment), radius: shadow.radius, offset: CGSize(width: shadow.x, height: shadow.y))
    }
}

extension ShapeStyle {
    public func shadow(_ style: ShadowStyle) -> _ShadowShapeStyle<Self> { _ShadowShapeStyle(base: self, shadow: style) }
}

extension ShapeStyle where Self == _ShadowShapeStyle<ForegroundStyle> {
    public static func shadow(_ style: ShadowStyle) -> _ShadowShapeStyle<ForegroundStyle> { _ShadowShapeStyle(base: ForegroundStyle(), shadow: style) }
}

/// Placeholder `Resolved` type of the built-in styles (they resolve directly to paint).
public struct _UnresolvedShapeStyle: ShapeStyle {
    public typealias Resolved = _UnresolvedShapeStyle
    public func resolve(in environment: EnvironmentValues) -> _UnresolvedShapeStyle { self }
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { .color(Color.Resolved(red: 0, green: 0, blue: 0, opacity: 0)) }
}

extension ShapeStyle where Resolved == _UnresolvedShapeStyle {
    public func resolve(in environment: EnvironmentValues) -> _UnresolvedShapeStyle { _UnresolvedShapeStyle() }
}

extension ShapeStyle {
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        resolve(in: environment)._resolvePaint(in: environment)
    }
}

extension Color.Resolved: ShapeStyle {
    public typealias Resolved = _UnresolvedShapeStyle
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { .color(self) }
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

/// A foreground style that refers to the foreground (`.foreground`, `.foreground.opacity(0.5)`) set
/// as the foreground: it resolves against the style it replaced, not against itself.
struct _InheritedForegroundStyle: ShapeStyle, Equatable {
    let style: AnyShapeStyle
    let parent: AnyShapeStyle?

    func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        var outer = environment
        outer.foregroundStyle = parent
        return style._resolvePaint(in: outer)
    }

    /// The value `.foregroundStyle(style)` stores over `current`.
    static func storing<S: ShapeStyle>(_ style: S, over current: AnyShapeStyle?) -> AnyShapeStyle? {
        if style is ForegroundStyle || (style as? AnyShapeStyle)?.base is ForegroundStyle { return current }
        let erased = AnyShapeStyle(style)
        guard String(reflecting: type(of: erased.base)).contains("ForegroundStyle") else { return erased }
        return AnyShapeStyle(_InheritedForegroundStyle(style: erased, parent: current))
    }
}

public struct HierarchicalShapeStyle: ShapeStyle, Hashable {
    let level: Int
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        // Explicit levels (`foregroundStyle(_:_:_:)`) win.
        let levels = environment.foregroundStyleLevels
        if level < levels.count { return levels[level]._resolvePaint(in: environment) }
        // macOS label colors: primary .85, secondary .5 (.55 dark), tertiary .26 (.25 dark),
        // quaternary .1; a custom foreground style is scaled by the same ratios.
        let isDark = environment.colorScheme == .dark
        let alphas: [Float] = isDark ? [0.85, 0.55, 0.25, 0.1] : [0.85, 0.5, 0.26, 0.1]
        let alpha = alphas[min(level, alphas.count - 1)]
        if let style = environment.foregroundStyle, !(style.base is HierarchicalShapeStyle) {
            var base = style._resolveColor(in: environment)
            base.opacity *= alpha / alphas[0]
            return .color(base)
        }
        var base = Color.primary.resolve(in: environment)
        base.opacity = alpha
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
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        if let custom = environment.backgroundStyle, !(custom.base is BackgroundStyle) { return custom._resolvePaint(in: environment) }
        return .color(Color.controlBackground.resolve(in: environment))
    }
}

/// Placeholder text: the foreground at the tertiary level.
public struct PlaceholderTextShapeStyle: ShapeStyle, Hashable {
    public init() {}
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { HierarchicalShapeStyle.tertiary._resolvePaint(in: environment) }
}

extension ShapeStyle where Self == PlaceholderTextShapeStyle { public static var placeholder: PlaceholderTextShapeStyle { .init() } }
extension ShapeStyle where Self == SeparatorShapeStyle { public static var separator: SeparatorShapeStyle { .init() } }
extension ShapeStyle where Self == BackgroundStyle { public static var background: BackgroundStyle { .init() } }

public struct AnyShapeStyle: ShapeStyle, Equatable {
    public static func == (lhs: AnyShapeStyle, rhs: AnyShapeStyle) -> Bool { GraphComparison.compareAny(lhs.base, rhs.base) }

    let base: any ShapeStyle
    public init<S: ShapeStyle>(_ style: S) {
        if let any = style as? AnyShapeStyle { base = any.base } else { base = style }
    }
    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint { base._resolvePaint(in: environment) }
    public func _resolveShadow(in environment: EnvironmentValues) -> ResolvedShadow? { base._resolveShadow(in: environment) }
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

// MARK: - Hierarchical levels of any style (`.background.secondary`, `.tint.tertiary`, ...)

public struct _ShapeStyleLevel<Base: ShapeStyle>: ShapeStyle {
    let base: Base
    let level: Int

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        if base is BackgroundStyle {
            // macOS secondary/tertiary system backgrounds.
            let levels = [Color.controlBackground, Color.secondaryBackground, Color.tertiaryBackground, Color.tertiaryBackground]
            return .color(levels[min(level, levels.count - 1)].resolve(in: environment))
        }
        let factors: [Float] = [1, 0.5, 0.3, 0.18, 0.1]
        var color = base._resolvePaint(in: environment).color
        color.opacity *= factors[min(level, factors.count - 1)]
        return .color(color)
    }
}

extension ShapeStyle {
    public var secondary: _ShapeStyleLevel<Self> { _ShapeStyleLevel(base: self, level: 1) }
    public var tertiary: _ShapeStyleLevel<Self> { _ShapeStyleLevel(base: self, level: 2) }
    public var quaternary: _ShapeStyleLevel<Self> { _ShapeStyleLevel(base: self, level: 3) }
    public var quinary: _ShapeStyleLevel<Self> { _ShapeStyleLevel(base: self, level: 4) }
}

extension Color {
    static let secondaryBackground = dynamic(rgb(0.965, 0.965, 0.965), rgb(0.157, 0.157, 0.157))
    static let tertiaryBackground = dynamic(rgb(0.925, 0.925, 0.925), rgb(0.2, 0.2, 0.2))
}

extension Color {
    /// This color mixed with `other` (`fraction` 0 is this color, 1 the other).
    public func mix(with other: Color, by fraction: Double, in colorSpace: Gradient.ColorSpace = .perceptual) -> Color {
        Color(storage: .mix(storage, other.storage, min(max(fraction, 0), 1)))
    }
}

extension Gradient {
    /// The space colors are interpolated in (interpolation here is in sRGB).
    public struct ColorSpace: Hashable, Sendable {
        let value: Int
        public static let device = ColorSpace(value: 0)
        public static let perceptual = ColorSpace(value: 1)
    }

    public func colorSpace(_ space: ColorSpace) -> Gradient { self }
}
