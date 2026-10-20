import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Modifiers that wrap their content in a platform container (opacity, clipping, tap targets,
/// transforms). They never change layout: the content's layout attribute is forwarded as is.
@MainActor
protocol PlatformEffectModifier: ViewModifier where Body == Never {
    static var pathComponent: String { get }
    func effect(size: CGSize) -> DisplayEffect
    func actions(modifier: Attribute<Self>) -> RenderActions
    /// Whether `actions` makes any (they read the modifier's latest value when they fire). No
    /// default: an effect that has actions but says it hasn't would silently lose them.
    static var hasActions: Bool { get }
}

extension PlatformEffectModifier {
    func actions(modifier: Attribute<Self>) -> RenderActions { RenderActions() }

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let inputs = inputs.with(path: pathComponent)
        let geometry = inputs.geometry
        // The modifier is read through its projection (the content's own cut-off is enough): an
        // attribute for it is made only for actions.
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            .effect(modifier.value.effect(size: geometry.value.size))
        }
        let actions = Self.hasActions ? AnyAttribute.withoutDependencies { modifier.attribute.value.actions(modifier: modifier.attribute) } : RenderActions()
        let render = inputs.makePlatformNode(content: content, actions: actions)
        var childInputs = inputs
        childInputs.render = render
        return body(childInputs)
    }
}

public struct _OpacityEffect: PlatformEffectModifier, Equatable {
    static var hasActions: Bool { false }
    let opacity: Double
    static var pathComponent: String { "opacity" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(opacity) }
}

public struct _ClipEffect<S: Shape>: PlatformEffectModifier {
    static var hasActions: Bool { false }
    let shape: S
    static var pathComponent: String { "clip" }
    func effect(size: CGSize) -> DisplayEffect { .clip(shape.path(in: CGRect(origin: .zero, size: size))) }
}

public struct _ContentShapeEffect<S: Shape>: PlatformEffectModifier {
    static var hasActions: Bool { false }
    let shape: S
    static var pathComponent: String { "contentShape" }
    func effect(size: CGSize) -> DisplayEffect { .contentShape(shape.path(in: CGRect(origin: .zero, size: size))) }
}

public struct _TransformEffect: PlatformEffectModifier, Equatable {
    static var hasActions: Bool { false }
    let offset: CGSize
    let scale: CGSize
    let rotation: Double
    var anchor = UnitPoint.center
    static var pathComponent: String { "transform" }
    func effect(size: CGSize) -> DisplayEffect { .transform(offset: offset, scale: scale, rotationDegrees: rotation, anchor: anchor) }
}

public struct _ShadowEffect: PlatformEffectModifier {
    static var hasActions: Bool { false }
    let shadow: Color
    let radius: CGFloat
    let offset: CGSize
    static var pathComponent: String { "shadow" }
    func effect(size: CGSize) -> DisplayEffect {
        .shadow(ResolvedShadow(color: shadow.resolve(in: EnvironmentValues()), radius: radius, offset: offset))
    }
}

public struct _TapGestureModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let count: Int
    let action: @MainActor () -> Void
    static var pathComponent: String { "onTapGesture" }
    func effect(size: CGSize) -> DisplayEffect { .tapTarget }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.primary = { [weak modifier] in
            guard let modifier else { return }
            let count = AnyAttribute.withoutDependencies { modifier.value.count }
            guard TapCounter.register(ObjectIdentifier(modifier), required: count) else { return }
            AnyAttribute.withoutDependencies { modifier.value.action() }
        }
        return actions
    }
}

/// Counts clicks on a tap target for `onTapGesture(count:)`: the backends report each click, and a double tap is
/// the second within the double-click interval. Kept by target, so an update between the clicks (the first
/// selected a row) doesn't start over.
@MainActor
enum TapCounter {
    static let interval: Double = 0.5
    private static var taps: [ObjectIdentifier: (count: Int, time: Double)] = [:]

    /// Whether this click completes `required` clicks.
    static func register(_ target: ObjectIdentifier, required: Int, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard required > 1 else { return true }
        taps = taps.filter { now - $0.value.time <= interval }
        let count = (taps[target]?.count ?? 0) + 1
        if count >= required {
            taps[target] = nil
            return true
        }
        taps[target] = (count, now)
        return false
    }
}

extension View {
    public func opacity(_ opacity: Double) -> some View { modifier(_OpacityEffect(opacity: opacity)) }

    public func hidden() -> some View { modifier(_OpacityEffect(opacity: 0)) }

    public func shadow(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modifier(_ShadowEffect(shadow: color, radius: radius, offset: CGSize(width: x, height: y)))
    }

    /// Hit testing uses view bounds; shapes are accepted for source compatibility.
    /// Hit testing (taps, hover, ...) uses `shape` instead of the view's bounds.
    public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> some View {
        modifier(_ContentShapeEffect(shape: shape))
    }

    /// Only the interaction kind changes hit testing; preview shapes (context menu, drag, hover
    /// and focus effects) are platform decorations.
    @ViewBuilder
    public func contentShape<S: Shape>(_ kind: ContentShapeKinds, _ shape: S, eoFill: Bool = false) -> some View {
        if kind.contains(.interaction) { modifier(_ContentShapeEffect(shape: shape)) } else { self }
    }

    public func compositingGroup() -> some View { self }
    public func drawingGroup(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear) -> some View { self }

    public func clipped(antialiased: Bool = false) -> some View { modifier(_ClipEffect(shape: Rectangle())) }

    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { modifier(_ClipEffect(shape: shape)) }

    public func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View {
        modifier(_ClipEffect(shape: RoundedRectangle(cornerRadius: radius)))
    }

    public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(_TransformEffect(offset: .zero, scale: CGSize(width: scale, height: scale), rotation: 0, anchor: anchor))
    }

    public func scaleEffect(_ scale: CGSize, anchor: UnitPoint = .center) -> some View {
        modifier(_TransformEffect(offset: .zero, scale: scale, rotation: 0, anchor: anchor))
    }

    public func scaleEffect(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> some View {
        modifier(_TransformEffect(offset: .zero, scale: CGSize(width: x, height: y), rotation: 0, anchor: anchor))
    }

    public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
        modifier(_TransformEffect(offset: .zero, scale: CGSize(width: 1, height: 1), rotation: angle.degrees, anchor: anchor))
    }

    public func onTapGesture(count: Int = 1, perform action: @escaping @MainActor () -> Void) -> some View {
        modifier(_TapGestureModifier(count: count, action: action))
    }

}

/// The kinds of interaction a content shape applies to.
public struct ContentShapeKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let interaction = ContentShapeKinds(rawValue: 1)
    public static let dragPreview = ContentShapeKinds(rawValue: 2)
    public static let contextMenuPreview = ContentShapeKinds(rawValue: 4)
    public static let hoverEffect = ContentShapeKinds(rawValue: 8)
    public static let focusEffect = ContentShapeKinds(rawValue: 16)
    public static let accessibility = ContentShapeKinds(rawValue: 32)
}

public struct FillStyle: Equatable, Sendable {
    public var isEOFilled: Bool
    public var isAntialiased: Bool
    public init(eoFill: Bool = false, antialiased: Bool = true) {
        isEOFilled = eoFill
        isAntialiased = antialiased
    }
}

public struct Angle: Hashable, Sendable {
    public var radians: Double
    public var degrees: Double { radians * 180 / .pi }
    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { radians = degrees * .pi / 180 }
    public static func degrees(_ value: Double) -> Angle { Angle(degrees: value) }
    public static func radians(_ value: Double) -> Angle { Angle(radians: value) }
    public static let zero = Angle(radians: 0)
}

