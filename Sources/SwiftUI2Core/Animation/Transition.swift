import Foundation

// MARK: - Custom transitions (`Transition` protocol)

public enum TransitionPhase: Equatable, Sendable {
    case willAppear, identity, didDisappear

    public var isIdentity: Bool { self == .identity }

    /// -1 before insertion, 0 when presented, 1 after removal.
    public var value: Double {
        switch self {
        case .willAppear: -1
        case .identity: 0
        case .didDisappear: 1
        }
    }
}

public struct TransitionProperties: Sendable {
    public var hasMotion: Bool
    public init(hasMotion: Bool = true) { self.hasMotion = hasMotion }
}

/// A transition described as a view modifier over its phases. The renderer animates platform
/// effects, so the body's opacity, scale, rotation and offset modifiers are extracted per phase;
/// other modifiers (e.g. blur) are ignored.
@MainActor @preconcurrency public protocol Transition {
    associatedtype Body: View
    typealias Content = PlaceholderContentView<Self>
    @ViewBuilder func body(content: Content, phase: TransitionPhase) -> Body
    static var properties: TransitionProperties { get }
}

extension Transition {
    public static var properties: TransitionProperties { TransitionProperties() }

    public func combined<T: Transition>(with other: T) -> AnyTransition {
        AnyTransition(self).combined(with: AnyTransition(other))
    }

    public func animation(_ animation: Animation?) -> AnyTransition {
        AnyTransition(self).animation(animation)
    }
}

@MainActor protocol _TransitionEffectSource {
    func _accumulate(into effect: inout AnyTransition.Effect)
}

extension ModifiedContent: _TransitionEffectSource {
    func _accumulate(into effect: inout AnyTransition.Effect) {
        (content as? _TransitionEffectSource)?._accumulate(into: &effect)
        switch modifier {
        case let opacity as _OpacityEffect:
            effect.opacity *= opacity.opacity
        case let transform as _TransformEffect:
            if transform.scale != CGSize(width: 1, height: 1) || transform.rotation != 0 { effect.scaleAnchor = transform.anchor }
            effect.scale.width *= transform.scale.width
            effect.scale.height *= transform.scale.height
            effect.rotationDegrees += transform.rotation
            effect.offset.width += transform.offset.width
            effect.offset.height += transform.offset.height
        case let offset as _OffsetEffect:
            effect.offset.width += offset.offset.width
            effect.offset.height += offset.offset.height
        default:
            break
        }
    }
}

extension _ConditionalContent: _TransitionEffectSource {
    func _accumulate(into effect: inout AnyTransition.Effect) {
        switch storage {
        case .trueContent(let content): (content as? _TransitionEffectSource)?._accumulate(into: &effect)
        case .falseContent(let content): (content as? _TransitionEffectSource)?._accumulate(into: &effect)
        }
    }
}

extension AnyTransition {
    @MainActor public init<T: Transition>(_ transition: T) {
        func effect(_ phase: TransitionPhase) -> Effect {
            var effect = Effect.identity
            (transition.body(content: PlaceholderContentView(content: EmptyView()), phase: phase) as? _TransitionEffectSource)?._accumulate(into: &effect)
            return effect
        }
        self.init(insertion: effect(.willAppear), removal: effect(.didDisappear))
    }
}

extension View {
    public func transition<T: Transition>(_ transition: T) -> some View {
        self.transition(AnyTransition(transition))
    }
}
