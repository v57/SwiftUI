import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// SF Symbol effects are Apple-specific animations; the API is accepted and the symbol is drawn
// without the effect.

public protocol SymbolEffect: Sendable {}
public protocol IndefiniteSymbolEffect: SymbolEffect {}
public protocol DiscreteSymbolEffect: SymbolEffect {}
public protocol TransitionSymbolEffect: SymbolEffect {}
public protocol ContentTransitionSymbolEffect: SymbolEffect {}

/// One effect value with chainable options (`.variableColor.iterative.reversing`, `.bounce.up`...).
public struct _SymbolEffectValue: IndefiniteSymbolEffect, DiscreteSymbolEffect, TransitionSymbolEffect, ContentTransitionSymbolEffect, Hashable {
    let name: String
    public var up: Self { self }
    public var down: Self { self }
    public var byLayer: Self { self }
    public var wholeSymbol: Self { self }
    public var iterative: Self { self }
    public var cumulative: Self { self }
    public var reversing: Self { self }
    public var nonReversing: Self { self }
    public var dimInactiveLayers: Self { self }
    public var hideInactiveLayers: Self { self }
    public var downUp: Self { self }
    public var upUp: Self { self }
    public var offUp: Self { self }
    public var clockwise: Self { self }
    public var counterClockwise: Self { self }
    public var pulse: Self { self }
}

public typealias BounceSymbolEffect = _SymbolEffectValue
public typealias PulseSymbolEffect = _SymbolEffectValue
public typealias VariableColorSymbolEffect = _SymbolEffectValue
public typealias ScaleSymbolEffect = _SymbolEffectValue
public typealias AppearSymbolEffect = _SymbolEffectValue
public typealias DisappearSymbolEffect = _SymbolEffectValue
public typealias ReplaceSymbolEffect = _SymbolEffectValue
public typealias RotateSymbolEffect = _SymbolEffectValue
public typealias WiggleSymbolEffect = _SymbolEffectValue
public typealias BreatheSymbolEffect = _SymbolEffectValue
public typealias AutomaticSymbolEffect = _SymbolEffectValue

extension SymbolEffect where Self == _SymbolEffectValue {
    public static var bounce: _SymbolEffectValue { _SymbolEffectValue(name: "bounce") }
    public static var pulse: _SymbolEffectValue { _SymbolEffectValue(name: "pulse") }
    public static var variableColor: _SymbolEffectValue { _SymbolEffectValue(name: "variableColor") }
    public static var scale: _SymbolEffectValue { _SymbolEffectValue(name: "scale") }
    public static var appear: _SymbolEffectValue { _SymbolEffectValue(name: "appear") }
    public static var disappear: _SymbolEffectValue { _SymbolEffectValue(name: "disappear") }
    public static var replace: _SymbolEffectValue { _SymbolEffectValue(name: "replace") }
    public static var rotate: _SymbolEffectValue { _SymbolEffectValue(name: "rotate") }
    public static var wiggle: _SymbolEffectValue { _SymbolEffectValue(name: "wiggle") }
    public static var breathe: _SymbolEffectValue { _SymbolEffectValue(name: "breathe") }
    public static var automatic: _SymbolEffectValue { _SymbolEffectValue(name: "automatic") }
}

public struct SymbolEffectOptions: Sendable, Hashable {
    public static let `default` = SymbolEffectOptions()
    public static let nonRepeating = SymbolEffectOptions()
    public static let repeating = SymbolEffectOptions()
    public static func `repeat`(_ count: Int) -> SymbolEffectOptions { SymbolEffectOptions() }
    public static func speed(_ speed: Double) -> SymbolEffectOptions { SymbolEffectOptions() }
    public func `repeat`(_ count: Int) -> SymbolEffectOptions { self }
    public func speed(_ speed: Double) -> SymbolEffectOptions { self }
    public enum RepeatBehavior: Sendable { case periodic, continuous }
    public static func `repeat`(_ behavior: RepeatBehavior) -> SymbolEffectOptions { SymbolEffectOptions() }
}

extension View {
    public func symbolEffect<E: SymbolEffect>(_ effect: E, options: SymbolEffectOptions = .default, isActive: Bool = true) -> some View { self }
    public func symbolEffect<E: SymbolEffect, V: Equatable>(_ effect: E, options: SymbolEffectOptions = .default, value: V) -> some View { self }
    public func symbolEffectsRemoved(_ isEnabled: Bool = true) -> some View { self }
}

// MARK: - Shape shorthands (`.clipShape(.capsule)`, `.background(.blue, in: .rect(cornerRadius: 8))`)

extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
    public static func capsule(style: RoundedCornerStyle) -> Capsule { Capsule() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}

extension Shape where Self == Ellipse {
    public static var ellipse: Ellipse { Ellipse() }
}

extension Shape where Self == Rectangle {
    public static var rect: Rectangle { Rectangle() }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
    public static func rect(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerSize: cornerSize, style: style)
    }
}

extension Shape where Self == UnevenRoundedRectangle {
    public static func rect(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0, topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topLeadingRadius, bottomLeadingRadius: bottomLeadingRadius, bottomTrailingRadius: bottomTrailingRadius, topTrailingRadius: topTrailingRadius, style: style)
    }
}

// MARK: - Accessibility environment

struct AccessibilityFlagKey<Tag>: EnvironmentKey { static var defaultValue: Bool { false } }
enum _ReduceMotion {}
enum _ReduceTransparency {}
enum _DifferentiateWithoutColor {}
enum _InvertColors {}
enum _ButtonShapes {}

public enum ColorSchemeContrast: Hashable, Sendable { case standard, increased }
public enum LegibilityWeight: Hashable, Sendable { case regular, bold }
struct ColorSchemeContrastKey: EnvironmentKey { static let defaultValue = ColorSchemeContrast.standard }
struct LegibilityWeightKey: EnvironmentKey { static let defaultValue: LegibilityWeight? = nil }

extension EnvironmentValues {
    public var accessibilityReduceMotion: Bool {
        get { self[AccessibilityFlagKey<_ReduceMotion>.self] }
        set { self[AccessibilityFlagKey<_ReduceMotion>.self] = newValue }
    }
    public var accessibilityReduceTransparency: Bool {
        get { self[AccessibilityFlagKey<_ReduceTransparency>.self] }
        set { self[AccessibilityFlagKey<_ReduceTransparency>.self] = newValue }
    }
    public var accessibilityDifferentiateWithoutColor: Bool {
        get { self[AccessibilityFlagKey<_DifferentiateWithoutColor>.self] }
        set { self[AccessibilityFlagKey<_DifferentiateWithoutColor>.self] = newValue }
    }
    public var accessibilityInvertColors: Bool {
        get { self[AccessibilityFlagKey<_InvertColors>.self] }
        set { self[AccessibilityFlagKey<_InvertColors>.self] = newValue }
    }
    public var accessibilityShowButtonShapes: Bool {
        get { self[AccessibilityFlagKey<_ButtonShapes>.self] }
        set { self[AccessibilityFlagKey<_ButtonShapes>.self] = newValue }
    }
    public var colorSchemeContrast: ColorSchemeContrast {
        get { self[ColorSchemeContrastKey.self] }
        set { self[ColorSchemeContrastKey.self] = newValue }
    }
    public var legibilityWeight: LegibilityWeight? {
        get { self[LegibilityWeightKey.self] }
        set { self[LegibilityWeightKey.self] = newValue }
    }
}
