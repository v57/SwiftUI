import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// SF Symbol effects: the effect (with its chained options) travels in the environment to images,
// and backends with symbol animation support play it.

public protocol SymbolEffect: Sendable {}
public protocol IndefiniteSymbolEffect: SymbolEffect {}
public protocol DiscreteSymbolEffect: SymbolEffect {}
public protocol TransitionSymbolEffect: SymbolEffect {}
public protocol ContentTransitionSymbolEffect: SymbolEffect {}

/// One effect value with chainable options (`.variableColor.iterative.reversing`, `.bounce.up`...).
public struct _SymbolEffectValue: IndefiniteSymbolEffect, DiscreteSymbolEffect, TransitionSymbolEffect, ContentTransitionSymbolEffect, Hashable {
    public let name: String
    /// Chained options in order (`up`, `byLayer`, `iterative`, ...).
    public private(set) var options: [String] = []

    init(name: String) { self.name = name }

    private func adding(_ option: String) -> Self {
        var copy = self
        copy.options.append(option)
        return copy
    }

    public var up: Self { adding("up") }
    public var down: Self { adding("down") }
    public var byLayer: Self { adding("byLayer") }
    public var wholeSymbol: Self { adding("wholeSymbol") }
    public var iterative: Self { adding("iterative") }
    public var cumulative: Self { adding("cumulative") }
    public var reversing: Self { adding("reversing") }
    public var nonReversing: Self { adding("nonReversing") }
    public var dimInactiveLayers: Self { adding("dimInactiveLayers") }
    public var hideInactiveLayers: Self { adding("hideInactiveLayers") }
    public var downUp: Self { adding("downUp") }
    public var upUp: Self { adding("upUp") }
    public var offUp: Self { adding("offUp") }
    public var clockwise: Self { adding("clockwise") }
    public var counterClockwise: Self { adding("counterClockwise") }
    public var pulse: Self { adding("pulse") }
    public var left: Self { adding("left") }
    public var right: Self { adding("right") }
    public var forward: Self { adding("forward") }
    public var backward: Self { adding("backward") }
    public var plain: Self { adding("plain") }
    public var magic: Self { self }
    public func magic(fallback: Self) -> Self { adding("magic") }
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
    public enum RepeatBehavior: Hashable, Sendable { case periodic, continuous }

    /// nil: the effect's default; 0: non-repeating.
    public var repeatCount: Int?
    public var repeatsContinuously = false
    public var speed: Double = 1

    public static let `default` = SymbolEffectOptions()
    public static let nonRepeating = SymbolEffectOptions(repeatCount: 0)
    public static let repeating = SymbolEffectOptions(repeatCount: nil)
    public static func `repeat`(_ count: Int) -> SymbolEffectOptions { SymbolEffectOptions(repeatCount: count) }
    public static func speed(_ speed: Double) -> SymbolEffectOptions { SymbolEffectOptions(speed: speed) }
    public static func `repeat`(_ behavior: RepeatBehavior) -> SymbolEffectOptions { SymbolEffectOptions(repeatsContinuously: behavior == .continuous) }

    public func `repeat`(_ count: Int) -> SymbolEffectOptions {
        var copy = self
        copy.repeatCount = count
        return copy
    }

    public func speed(_ speed: Double) -> SymbolEffectOptions {
        var copy = self
        copy.speed = speed
        return copy
    }

    public func `repeat`(_ behavior: RepeatBehavior) -> SymbolEffectOptions {
        var copy = self
        copy.repeatsContinuously = behavior == .continuous
        return copy
    }
}

/// A symbol effect requested for images in a subtree.
public struct _SymbolEffectRequest: Hashable, Sendable {
    public var effect: _SymbolEffectValue
    public var options: SymbolEffectOptions
    /// Indefinite effects run while active.
    public var isActive: Bool
    /// Discrete effects play once each time this changes (nil for indefinite effects).
    public var trigger: Int?
}

struct SymbolEffectsKey: EnvironmentKey { static let defaultValue: [_SymbolEffectRequest] = [] }
struct SymbolEffectsRemovedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var _symbolEffects: [_SymbolEffectRequest] {
        get { self[SymbolEffectsKey.self] }
        set { self[SymbolEffectsKey.self] = newValue }
    }

    var _symbolEffectsRemoved: Bool {
        get { self[SymbolEffectsRemovedKey.self] }
        set { self[SymbolEffectsRemovedKey.self] = newValue }
    }
}

extension View {
    public func symbolEffect<E: SymbolEffect>(_ effect: E, options: SymbolEffectOptions = .default, isActive: Bool = true) -> some View {
        transformEnvironment(\._symbolEffects) { effects in
            guard let value = effect as? _SymbolEffectValue else { return }
            effects.append(_SymbolEffectRequest(effect: value, options: options, isActive: isActive, trigger: nil))
        }
    }

    /// Plays a discrete effect each time `value` changes.
    public func symbolEffect<E: SymbolEffect, V: Equatable>(_ effect: E, options: SymbolEffectOptions = .default, value: V) -> some View {
        modifier(_DiscreteSymbolEffectModifier(effect: effect as? _SymbolEffectValue, options: options, value: value))
    }

    public func symbolEffectsRemoved(_ isEnabled: Bool = true) -> some View {
        environment(\._symbolEffectsRemoved, isEnabled)
    }
}

struct _DiscreteSymbolEffectModifier<V: Equatable>: ViewModifier {
    let effect: _SymbolEffectValue?
    let options: SymbolEffectOptions
    let value: V
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\._symbolEffects) { effects in
                guard let effect else { return }
                effects.append(_SymbolEffectRequest(effect: effect, options: options, isActive: true, trigger: trigger))
            }
            .onChange(of: value) { trigger += 1 }
    }
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
    /// The writable form of `colorSchemeContrast` (as Apple's, for passing a window's contrast on).
    public var _colorSchemeContrast: ColorSchemeContrast {
        get { self[ColorSchemeContrastKey.self] }
        set { self[ColorSchemeContrastKey.self] = newValue }
    }
    public var legibilityWeight: LegibilityWeight? {
        get { self[LegibilityWeightKey.self] }
        set { self[LegibilityWeightKey.self] = newValue }
    }
}

// MARK: - Focus / search state in the environment

struct IsFocusedKey: EnvironmentKey { static let defaultValue = false }
struct IsSearchingKey: EnvironmentKey { static let defaultValue = false }
struct IsFocusEffectEnabledKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Whether the nearest focusable ancestor has focus.
    public var isFocused: Bool {
        get { self[IsFocusedKey.self] }
        set { self[IsFocusedKey.self] = newValue }
    }
    /// Whether the enclosing searchable is being searched.
    public var isSearching: Bool {
        get { self[IsSearchingKey.self] }
        set { self[IsSearchingKey.self] = newValue }
    }
    public var isFocusEffectEnabled: Bool {
        get { self[IsFocusEffectEnabledKey.self] }
        set { self[IsFocusEffectEnabledKey.self] = newValue }
    }
}
