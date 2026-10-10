import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Scroll configuration (environment read by ScrollView)

enum ScrollTargetKind: Hashable, Sendable { case none, paging, viewAligned }

/// Scroll view behavior set by `scrollIndicators`, `scrollBounceBehavior`, `contentMargins`, ...
/// Applies to the scroll views inside the modified view.
struct ScrollConfiguration: Equatable, Sendable {
    var verticalIndicator = ScrollIndicatorVisibility.automatic
    var horizontalIndicator = ScrollIndicatorVisibility.automatic
    var verticalBounce = ScrollBounceBehavior.automatic
    var horizontalBounce = ScrollBounceBehavior.automatic
    var clipDisabled = false
    var contentMargins = EdgeInsets()
    var defaultAnchor: UnitPoint?
    var targetBehavior = ScrollTargetKind.none
    var flashCount = 0
}

struct ScrollConfigurationKey: EnvironmentKey { static let defaultValue = ScrollConfiguration() }

extension EnvironmentValues {
    var scrollConfiguration: ScrollConfiguration {
        get { self[ScrollConfigurationKey.self] }
        set { self[ScrollConfigurationKey.self] = newValue }
    }

    /// The vertical scroll indicator visibility (`scrollIndicators`).
    public var verticalScrollIndicatorVisibility: ScrollIndicatorVisibility {
        get { scrollConfiguration.verticalIndicator }
        set { scrollConfiguration.verticalIndicator = newValue }
    }

    public var horizontalScrollIndicatorVisibility: ScrollIndicatorVisibility {
        get { scrollConfiguration.horizontalIndicator }
        set { scrollConfiguration.horizontalIndicator = newValue }
    }

    public var verticalScrollBounceBehavior: ScrollBounceBehavior {
        get { scrollConfiguration.verticalBounce }
        set { scrollConfiguration.verticalBounce = newValue }
    }

    public var horizontalScrollBounceBehavior: ScrollBounceBehavior {
        get { scrollConfiguration.horizontalBounce }
        set { scrollConfiguration.horizontalBounce = newValue }
    }
}

extension View {
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: Axis.Set = [.vertical, .horizontal]) -> some View {
        transformEnvironment(\.scrollConfiguration) { configuration in
            if axes.contains(.vertical) { configuration.verticalIndicator = visibility }
            if axes.contains(.horizontal) { configuration.horizontalIndicator = visibility }
        }
    }

    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View {
        transformEnvironment(\.scrollConfiguration) { configuration in
            if axes.contains(.vertical) { configuration.verticalBounce = behavior }
            if axes.contains(.horizontal) { configuration.horizontalBounce = behavior }
        }
    }

    public func scrollClipDisabled(_ disabled: Bool = true) -> some View {
        transformEnvironment(\.scrollConfiguration) { $0.clipDisabled = disabled }
    }

    /// Insets the scroll content (indicator margins are not configurable on macOS scrollers).
    public func contentMargins(_ edges: Edge.Set = .all, _ insets: EdgeInsets, for placement: ContentMarginPlacement = .automatic) -> some View {
        transformEnvironment(\.scrollConfiguration) { configuration in
            guard placement != .scrollIndicators else { return }
            if edges.contains(.top) { configuration.contentMargins.top = insets.top }
            if edges.contains(.leading) { configuration.contentMargins.leading = insets.leading }
            if edges.contains(.bottom) { configuration.contentMargins.bottom = insets.bottom }
            if edges.contains(.trailing) { configuration.contentMargins.trailing = insets.trailing }
        }
    }

    public func contentMargins(_ edges: Edge.Set = .all, _ length: CGFloat?, for placement: ContentMarginPlacement = .automatic) -> some View {
        let value = length ?? 16
        return contentMargins(edges, EdgeInsets(top: value, leading: value, bottom: value, trailing: value), for: placement)
    }

    public func contentMargins(_ length: CGFloat, for placement: ContentMarginPlacement = .automatic) -> some View {
        contentMargins(.all, length, for: placement)
    }

    /// Where scroll views start (e.g. `.bottom` for chat transcripts).
    public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        transformEnvironment(\.scrollConfiguration) { $0.defaultAnchor = anchor }
    }

    public func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View {
        transformEnvironment(\.scrollConfiguration) { configuration in
            if role == .initialOffset { configuration.defaultAnchor = anchor }
        }
    }

    /// Paging snaps to whole viewport pages; view-aligned snaps to the nearest scroll target.
    public func scrollTargetBehavior<B: ScrollTargetBehavior>(_ behavior: B) -> some View {
        let kind: ScrollTargetKind = behavior is PagingScrollTargetBehavior ? .paging : behavior is ViewAlignedScrollTargetBehavior ? .viewAligned : .none
        return transformEnvironment(\.scrollConfiguration) { $0.targetBehavior = kind }
    }

    public func scrollIndicatorsFlash(onAppear: Bool) -> some View {
        transformEnvironment(\.scrollConfiguration) { if onAppear { $0.flashCount += 1 } }
    }

    public func scrollIndicatorsFlash<V: Equatable>(trigger value: V) -> some View {
        modifier(_ScrollIndicatorsFlashModifier(value: value))
    }
}

public enum ScrollAnchorRole: Hashable, Sendable { case initialOffset, sizeChanges, alignment }

struct _ScrollIndicatorsFlashModifier<V: Equatable>: ViewModifier {
    let value: V
    @State private var flashes = 0
    func body(content: Content) -> some View {
        let flashes = self.flashes
        content
            .transformEnvironment(\.scrollConfiguration) { $0.flashCount += flashes }
            .onChange(of: value) { self.flashes += 1 }
    }
}

// MARK: - Scroll phase

public struct ScrollPhaseChangeContext {
    public var geometry: ScrollGeometry
    public var velocity: CGVector? { nil }
}

extension ScrollPhase {
    public var isScrolling: Bool { self != .idle }
}

/// One `onScrollPhaseChange` registration.
@MainActor
final class ScrollPhaseObserver {
    var action: (@MainActor (ScrollPhase, ScrollPhase, ScrollPhaseChangeContext) -> Void)?
    var phase = ScrollPhase.idle
    init() {}
}

extension ScrollPhaseObserver: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: ScrollPhaseObserver, _ rhs: ScrollPhaseObserver) -> Bool { lhs === rhs }
}

struct ScrollPhaseObserversKey: EnvironmentKey { static let defaultValue: [ScrollPhaseObserver] = [] }

extension EnvironmentValues {
    var scrollPhaseObservers: [ScrollPhaseObserver] {
        get { self[ScrollPhaseObserversKey.self] }
        set { self[ScrollPhaseObserversKey.self] = newValue }
    }
}

struct _ScrollPhaseChangeModifier: ViewModifier {
    let action: @MainActor (ScrollPhase, ScrollPhase, ScrollPhaseChangeContext) -> Void
    @State private var observer = ScrollPhaseObserver()

    func body(content: Content) -> some View {
        observer.action = action
        let observer = self.observer
        return content.transformEnvironment(\.scrollPhaseObservers) { $0.append(observer) }
    }
}

extension View {
    public func onScrollPhaseChange(_ action: @escaping @MainActor (_ oldPhase: ScrollPhase, _ newPhase: ScrollPhase) -> Void) -> some View {
        modifier(_ScrollPhaseChangeModifier { old, new, _ in action(old, new) })
    }

    public func onScrollPhaseChange(_ action: @escaping @MainActor (_ oldPhase: ScrollPhase, _ newPhase: ScrollPhase, _ context: ScrollPhaseChangeContext) -> Void) -> some View {
        modifier(_ScrollPhaseChangeModifier(action: action))
    }
}

// MARK: - Scroll target visibility

/// One `onScrollTargetVisibilityChange` registration (evaluated after scroll updates).
@MainActor
final class ScrollTargetVisibilityObserver {
    var threshold: Double = 0.5
    var update: (@MainActor ([AnyHashable]) -> Void)?
    var last: [AnyHashable]?
}

extension ScrollTargetVisibilityObserver: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: ScrollTargetVisibilityObserver, _ rhs: ScrollTargetVisibilityObserver) -> Bool { lhs === rhs }
}

struct ScrollTargetVisibilityObserversKey: EnvironmentKey { static let defaultValue: [ScrollTargetVisibilityObserver] = [] }

extension EnvironmentValues {
    var scrollTargetVisibilityObservers: [ScrollTargetVisibilityObserver] {
        get { self[ScrollTargetVisibilityObserversKey.self] }
        set { self[ScrollTargetVisibilityObserversKey.self] = newValue }
    }
}

struct _ScrollTargetVisibilityModifier<ID: Hashable>: ViewModifier {
    let threshold: Double
    let action: @MainActor ([ID]) -> Void
    @State private var observer = ScrollTargetVisibilityObserver()

    func body(content: Content) -> some View {
        let action = self.action
        observer.threshold = threshold
        observer.update = { ids in action(ids.compactMap { $0.base as? ID }) }
        let observer = self.observer
        return content.transformEnvironment(\.scrollTargetVisibilityObservers) { $0.append(observer) }
    }
}

extension View {
    /// Reports the identifiers of the scroll targets (children with explicit ids) that are at least
    /// `threshold` visible, in order.
    public func onScrollTargetVisibilityChange<ID: Hashable>(idType: ID.Type, threshold: Double = 0.5, _ action: @escaping @MainActor ([ID]) -> Void) -> some View {
        modifier(_ScrollTargetVisibilityModifier(threshold: threshold, action: action))
    }
}

/// Fraction of `frame` inside `viewport` (1 when the frame is empty and inside).
func visibleFraction(of frame: CGRect, in viewport: CGRect) -> Double {
    let area = frame.width * frame.height
    guard area > 0 else { return viewport.contains(frame.origin) ? 1 : 0 }
    let visible = frame.intersection(viewport)
    guard !visible.isNull else { return 0 }
    return Double(visible.width * visible.height / area)
}

// MARK: - View visibility in scroll views

public struct _ScrollVisibilityModifier: ViewModifier {
    let threshold: Double
    let action: @MainActor (Bool) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        guard let viewport = inputs.scrollViewport else { return body(inputs) }
        let geometry = inputs.geometry
        let host = inputs.host
        let visible = Attribute<Bool>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let threshold = modifier.attribute.value.threshold
            return visibleFraction(of: geometry.value.frame, in: viewport.value) >= max(threshold, 0.0001)
        }
        var reported: Bool?
        visible.onChange = { isVisible in
            // Like SwiftUI: report changes, and an initially visible view once.
            guard reported != isVisible, reported != nil || isVisible else { reported = isVisible; return }
            reported = isVisible
            host.enqueueAfterUpdate { AnyAttribute.withoutDependencies { modifier.attribute.value.action(isVisible) } }
        }
        visible.isEager = true
        return body(inputs)
    }
}

extension View {
    public func onScrollVisibilityChange(threshold: Double = 0.5, _ action: @escaping @MainActor (Bool) -> Void) -> some View {
        modifier(_ScrollVisibilityModifier(threshold: threshold, action: action))
    }
}

// MARK: - Visual effects

/// Geometry-independent rendering effects (`visualEffect`, `scrollTransition`). Only affect
/// rendering, never layout. Color filters and blurs are accepted and ignored.
public protocol VisualEffect: Sendable {
    func _apply(to values: inout _VisualEffectValues)
}

public struct _VisualEffectValues: Equatable, Sendable {
    public var opacity: Double = 1
    public var scale = CGSize(width: 1, height: 1)
    public var scaleAnchor = UnitPoint.center
    public var offset = CGSize.zero
    public var rotationDegrees: Double = 0

    static func interpolate(_ a: Self, _ b: Self, _ t: Double) -> Self {
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
        return _VisualEffectValues(
            opacity: a.opacity + (b.opacity - a.opacity) * t,
            scale: CGSize(width: lerp(a.scale.width, b.scale.width), height: lerp(a.scale.height, b.scale.height)),
            scaleAnchor: t < 0.5 ? a.scaleAnchor : b.scaleAnchor,
            offset: CGSize(width: lerp(a.offset.width, b.offset.width), height: lerp(a.offset.height, b.offset.height)),
            rotationDegrees: a.rotationDegrees + (b.rotationDegrees - a.rotationDegrees) * t
        )
    }

    /// Offset that makes a center-anchored scale behave as if anchored at `scaleAnchor`.
    func anchorCorrection(for size: CGSize) -> CGSize {
        CGSize(width: (scaleAnchor.x - 0.5) * size.width * (1 - scale.width),
               height: (scaleAnchor.y - 0.5) * size.height * (1 - scale.height))
    }
}

public struct EmptyVisualEffect: VisualEffect {
    public init() {}
    public func _apply(to values: inout _VisualEffectValues) {}
}

public struct _VisualEffectStep: VisualEffect {
    let base: any VisualEffect
    let transform: @Sendable (inout _VisualEffectValues) -> Void
    public func _apply(to values: inout _VisualEffectValues) {
        base._apply(to: &values)
        transform(&values)
    }
}

extension VisualEffect {
    private func then(_ transform: @escaping @Sendable (inout _VisualEffectValues) -> Void) -> _VisualEffectStep {
        _VisualEffectStep(base: self, transform: transform)
    }

    public func opacity(_ opacity: Double) -> _VisualEffectStep { then { $0.opacity *= opacity } }
    public func offset(_ offset: CGSize) -> _VisualEffectStep { then { $0.offset.width += offset.width; $0.offset.height += offset.height } }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> _VisualEffectStep { offset(CGSize(width: x, height: y)) }
    public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> _VisualEffectStep { scaleEffect(x: scale, y: scale, anchor: anchor) }
    public func scaleEffect(_ scale: CGSize, anchor: UnitPoint = .center) -> _VisualEffectStep { scaleEffect(x: scale.width, y: scale.height, anchor: anchor) }
    public func scaleEffect(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> _VisualEffectStep {
        then { $0.scale.width *= x; $0.scale.height *= y; $0.scaleAnchor = anchor }
    }
    public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> _VisualEffectStep { then { $0.rotationDegrees += angle.degrees } }
    public func blur(radius: CGFloat, opaque: Bool = false) -> _VisualEffectStep { then { _ in } }
    public func brightness(_ amount: Double) -> _VisualEffectStep { then { _ in } }
    public func contrast(_ amount: Double) -> _VisualEffectStep { then { _ in } }
    public func saturation(_ amount: Double) -> _VisualEffectStep { then { _ in } }
    public func grayscale(_ amount: Double) -> _VisualEffectStep { then { _ in } }
    public func hueRotation(_ angle: Angle) -> _VisualEffectStep { then { _ in } }
    public func colorMultiply(_ color: Color) -> _VisualEffectStep { then { _ in } }
}

/// Renders computed visual effect values through opacity and transform platform effects.
@MainActor
func makeVisualEffect(values: Attribute<_VisualEffectValues>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
    let geometry = inputs.geometry
    let opacity = Attribute<_OpacityEffect>(inputs.subgraph, isEqual: { $0 == $1 }) { _OpacityEffect(opacity: values.value.opacity) }
    let transform = Attribute<_TransformEffect>(inputs.subgraph, isEqual: { $0 == $1 }) {
        let current = values.value
        // Effects may be evaluated while the graph is built, before the geometry is bound.
        let correction = current.anchorCorrection(for: geometry.valueIfPresent?.size ?? .zero)
        return _TransformEffect(offset: CGSize(width: current.offset.width + correction.width, height: current.offset.height + correction.height),
                                scale: current.scale, rotation: current.rotationDegrees)
    }
    return _OpacityEffect._makeView(modifier: _GraphValue(opacity), inputs: inputs) { inner in
        _TransformEffect._makeView(modifier: _GraphValue(transform), inputs: inner, body: body)
    }
}

public struct _VisualEffectModifier<Effect: VisualEffect>: ViewModifier {
    let effect: @Sendable (EmptyVisualEffect, GeometryProxy) -> Effect
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let geometry = inputs.geometry
        let spaces = inputs.coordinateSpaces
        let values = Attribute<_VisualEffectValues>(inputs.subgraph, isEqual: { $0 == $1 }) {
            var values = _VisualEffectValues()
            let placed = geometry.valueIfPresent ?? ViewGeometry(origin: .zero, size: .zero, proposal: .unspecified)
            modifier.attribute.value.effect(EmptyVisualEffect(), GeometryProxy(geometry: placed, spaces: spaces))._apply(to: &values)
            return values
        }
        return makeVisualEffect(values: values, inputs: inputs, body: body)
    }
}

extension View {
    /// Rendering effects computed from the view's geometry (they never change layout).
    public func visualEffect<E: VisualEffect>(_ effect: @escaping @Sendable (EmptyVisualEffect, GeometryProxy) -> E) -> some View {
        modifier(_VisualEffectModifier(effect: effect))
    }
}

// MARK: - Scroll transitions

public enum ScrollTransitionPhase: Hashable, Sendable {
    case topLeading, identity, bottomTrailing
    public var isIdentity: Bool { self == .identity }
    public var value: Double {
        switch self {
        case .topLeading: -1
        case .identity: 0
        case .bottomTrailing: 1
        }
    }
}

public struct ScrollTransitionConfiguration: Sendable {
    enum Kind: Sendable { case identity, interactive, animated }
    var kind: Kind
    var threshold: Double = 0

    public static let identity = ScrollTransitionConfiguration(kind: .identity)
    public static let interactive = ScrollTransitionConfiguration(kind: .interactive)
    public static let animated = ScrollTransitionConfiguration(kind: .animated)
    public static func animated(_ animation: Animation = .default) -> ScrollTransitionConfiguration { ScrollTransitionConfiguration(kind: .animated) }
    public static func interactive(timingCurve: UnitCurve) -> ScrollTransitionConfiguration { .interactive }

    /// Visibility at which the view reaches the identity phase.
    public func threshold(_ threshold: ScrollTransitionThreshold) -> ScrollTransitionConfiguration {
        var copy = self
        copy.threshold = threshold.amount
        return copy
    }

    public func animation(_ animation: Animation) -> ScrollTransitionConfiguration { self }
}

public struct ScrollTransitionThreshold: Sendable {
    let amount: Double
    public static let visible = ScrollTransitionThreshold(amount: 0)
    public static let hidden = ScrollTransitionThreshold(amount: 0)
    public static var centered: ScrollTransitionThreshold { ScrollTransitionThreshold(amount: 1) }
    public static func visible(_ amount: Double) -> ScrollTransitionThreshold { ScrollTransitionThreshold(amount: amount) }
}

public struct _ScrollTransitionModifier<Effect: VisualEffect>: ViewModifier {
    let topLeading: ScrollTransitionConfiguration
    let bottomTrailing: ScrollTransitionConfiguration
    let axis: Axis?
    let transition: @Sendable (EmptyVisualEffect, ScrollTransitionPhase) -> Effect
    public typealias Body = Never

    /// Phase progress of `frame` relative to `viewport`: negative before it, positive after, 0
    /// when fully visible.
    static func progress(of frame: CGRect, in viewport: CGRect, axis: Axis) -> Double {
        let (minFrame, maxFrame, minPort, maxPort, length) = axis == .vertical
            ? (frame.minY, frame.maxY, viewport.minY, viewport.maxY, frame.height)
            : (frame.minX, frame.maxX, viewport.minX, viewport.maxX, frame.width)
        guard length > 0 else { return 0 }
        if minFrame < minPort { return -min(1, Double((minPort - minFrame) / length)) }
        if maxFrame > maxPort { return min(1, Double((maxFrame - maxPort) / length)) }
        return 0
    }

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        guard let viewport = inputs.scrollViewport else { return body(inputs) }
        let geometry = inputs.geometry
        let values = Attribute<_VisualEffectValues>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let current = modifier.attribute.value
            func effect(_ phase: ScrollTransitionPhase) -> _VisualEffectValues {
                var values = _VisualEffectValues()
                current.transition(EmptyVisualEffect(), phase)._apply(to: &values)
                return values
            }
            guard let frame = geometry.valueIfPresent?.frame, let visible = viewport.valueIfPresent else { return effect(.identity) }
            let progress = progress(of: frame, in: visible, axis: current.axis ?? .vertical)
            guard progress != 0 else { return effect(.identity) }
            let phase: ScrollTransitionPhase = progress < 0 ? .topLeading : .bottomTrailing
            let configuration = progress < 0 ? current.topLeading : current.bottomTrailing
            switch configuration.kind {
            case .identity:
                return effect(.identity)
            case .interactive:
                return _VisualEffectValues.interpolate(effect(.identity), effect(phase), abs(progress))
            case .animated:
                // Discrete: the edge phase once less than the threshold remains visible.
                return 1 - abs(progress) >= max(configuration.threshold, 0.5) ? effect(.identity) : effect(phase)
            }
        }
        return makeVisualEffect(values: values, inputs: inputs, body: body)
    }
}

extension View {
    public func scrollTransition<E: VisualEffect>(_ configuration: ScrollTransitionConfiguration = .interactive, axis: Axis? = nil, transition: @escaping @Sendable (EmptyVisualEffect, ScrollTransitionPhase) -> E) -> some View {
        modifier(_ScrollTransitionModifier(topLeading: configuration, bottomTrailing: configuration, axis: axis, transition: transition))
    }

    public func scrollTransition<E: VisualEffect>(topLeading: ScrollTransitionConfiguration, bottomTrailing: ScrollTransitionConfiguration, axis: Axis? = nil, transition: @escaping @Sendable (EmptyVisualEffect, ScrollTransitionPhase) -> E) -> some View {
        modifier(_ScrollTransitionModifier(topLeading: topLeading, bottomTrailing: bottomTrailing, axis: axis, transition: transition))
    }
}
