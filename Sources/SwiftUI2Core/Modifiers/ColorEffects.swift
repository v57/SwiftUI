import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A color filter applied to a view's rendering (backends map these to their compositor's
/// filters; amounts animate).
public enum ColorFilter: Hashable, Sendable {
    case grayscale(Double)
    case saturation(Double)
    case brightness(Double)
    case contrast(Double)
    /// Hue rotation in radians.
    case hueRotation(Double)
    case invert
    case multiply(Color.Resolved)
    case luminanceToAlpha

    static func interpolate(_ a: ColorFilter, _ b: ColorFilter, _ t: Double) -> ColorFilter? {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        switch (a, b) {
        case let (.grayscale(x), .grayscale(y)): return .grayscale(l(x, y))
        case let (.saturation(x), .saturation(y)): return .saturation(l(x, y))
        case let (.brightness(x), .brightness(y)): return .brightness(l(x, y))
        case let (.contrast(x), .contrast(y)): return .contrast(l(x, y))
        case let (.hueRotation(x), .hueRotation(y)): return .hueRotation(l(x, y))
        case let (.multiply(x), .multiply(y)): return .multiply(.interpolate(x, y, t))
        case (.invert, .invert), (.luminanceToAlpha, .luminanceToAlpha): return b
        default: return nil
        }
    }
}

public struct _ColorFilterEffect: PlatformEffectModifier, Equatable {
    let filter: ColorFilter
    static var pathComponent: String { "colorFilter" }
    func effect(size: CGSize) -> DisplayEffect { .colorFilter(filter) }
}

public struct _BlendModeEffect: PlatformEffectModifier, Equatable {
    let mode: BlendMode
    static var pathComponent: String { "blendMode" }
    func effect(size: CGSize) -> DisplayEffect { .blendMode(mode) }
}

/// Redacted content (`redacted(reason: .placeholder)`): text and images draw as placeholders.
struct RedactionReasonsKey: EnvironmentKey { static let defaultValue: RedactionReasons = [] }

struct PrivacySensitiveKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    public var redactionReasons: RedactionReasons {
        get { self[RedactionReasonsKey.self] }
        set { self[RedactionReasonsKey.self] = newValue }
    }

    var _isPrivacySensitive: Bool {
        get { self[PrivacySensitiveKey.self] }
        set { self[PrivacySensitiveKey.self] = newValue }
    }

    /// Whether content here draws as placeholders.
    var _isRedacted: Bool {
        redactionReasons.contains(.placeholder) || (redactionReasons.contains(.privacy) && _isPrivacySensitive)
    }
}

extension View {
    public func grayscale(_ amount: Double) -> some View { modifier(_ColorFilterEffect(filter: .grayscale(amount))) }
    public func saturation(_ amount: Double) -> some View { modifier(_ColorFilterEffect(filter: .saturation(amount))) }
    public func brightness(_ amount: Double) -> some View { modifier(_ColorFilterEffect(filter: .brightness(amount))) }
    public func contrast(_ amount: Double) -> some View { modifier(_ColorFilterEffect(filter: .contrast(amount))) }
    public func hueRotation(_ angle: Angle) -> some View { modifier(_ColorFilterEffect(filter: .hueRotation(angle.radians))) }
    public func colorInvert() -> some View { modifier(_ColorFilterEffect(filter: .invert)) }
    public func colorMultiply(_ color: Color) -> some View { modifier(_ColorMultiplyModifier(color: color)) }
    public func luminanceToAlpha() -> some View { modifier(_ColorFilterEffect(filter: .luminanceToAlpha)) }
    public func blendMode(_ mode: BlendMode) -> some View { modifier(_BlendModeEffect(mode: mode)) }

    public func redacted(reason: RedactionReasons) -> some View {
        transformEnvironment(\.redactionReasons) { $0.formUnion(reason) }
    }

    public func unredacted() -> some View { environment(\.redactionReasons, []) }

    /// Marks content hidden when redacted for privacy (`redacted(reason: .privacy)`).
    public func privacySensitive(_ sensitive: Bool = true) -> some View { environment(\._isPrivacySensitive, sensitive) }
}

/// Resolves the multiplied color in the environment (dynamic colors follow the color scheme).
struct _ColorMultiplyModifier: ViewModifier {
    let color: Color
    @Environment(\.self) private var environment
    func body(content: Content) -> some View {
        content.modifier(_ColorFilterEffect(filter: .multiply(color.resolve(in: environment))))
    }
}
