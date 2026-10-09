import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Subtree-scoped transaction adjustments (`.animation(_:value:)`, `.transaction { }`), resolved
/// lazily for each change against the update's root transaction (outermost scope first).
@MainActor
final class AnimationScope {
    enum Kind {
        /// Animate with `animation` when the observed value changed in the current update.
        case value(changed: @MainActor () -> Bool, animation: @MainActor () -> Animation?)
        /// Always apply (deprecated `.animation(_:)`).
        case always(@MainActor () -> Animation?)
        case transform(@MainActor (inout Transaction) -> Void)
    }

    let parent: AnimationScope?
    let kind: Kind

    init(parent: AnimationScope?, kind: Kind) {
        self.parent = parent
        self.kind = kind
    }

    func resolve(_ base: Transaction) -> Transaction {
        var transaction = parent?.resolve(base) ?? base
        AnyAttribute.withoutDependencies {
            switch kind {
            case let .value(changed, animation):
                if changed(), !transaction.disablesAnimations { transaction.animation = animation() }
            case let .always(animation):
                if !transaction.disablesAnimations { transaction.animation = animation() }
            case let .transform(transform):
                transform(&transaction)
            }
        }
        return transaction
    }
}

extension _ViewInputs {
    /// The transaction a change of this view was made in.
    var transaction: Transaction {
        animationScope?.resolve(host.currentTransaction) ?? host.currentTransaction
    }
}

public struct _ValueAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let source = modifier.attribute
        let changedInUpdate = LastValue<Int>()
        let observer = Attribute<Value>(inputs.subgraph, isEqual: { $0 == $1 }) { source.value.value }
        observer.order = inputs.depth
        var first = true
        observer.onChange = { _ in
            if first { first = false; return }
            changedInUpdate.value = host.updateSequence
        }
        observer.isEager = true
        var childInputs = inputs
        childInputs.animationScope = AnimationScope(parent: inputs.animationScope, kind: .value(
            changed: {
                _ = observer.value // make sure the comparison ran in this update
                return changedInUpdate.value == host.updateSequence
            },
            animation: { source.value.animation }
        ))
        return body(childInputs)
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        // Applies to the elements' unary graphs (per-element, like other modifiers).
        let content = body(inputs)
        let list = content.list.mapElements(in: inputs.subgraph) { element in
            ViewListElement(traits: element.traits) { placement in
                Self._makeView(modifier: modifier, inputs: inputs.instantiate(placement)) { element.make($0) }
            }
        }
        return _ViewListOutputs(list: list)
    }
}

public struct _AlwaysAnimationModifier: ViewModifier {
    let animation: Animation?
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var childInputs = inputs
        let source = modifier.attribute
        childInputs.animationScope = AnimationScope(parent: inputs.animationScope, kind: .always { source.value.animation })
        return body(childInputs)
    }
}

public struct _TransactionModifier: ViewModifier {
    let transform: @MainActor (inout Transaction) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var childInputs = inputs
        let source = modifier.attribute
        childInputs.animationScope = AnimationScope(parent: inputs.animationScope, kind: .transform { source.value.transform(&$0) })
        return body(childInputs)
    }
}

extension View {
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(_ValueAnimationModifier(animation: animation, value: value))
    }

    @available(*, deprecated, message: "Use animation(_:value:) instead.")
    public func animation(_ animation: Animation?) -> some View {
        modifier(_AlwaysAnimationModifier(animation: animation))
    }

    public func transaction(_ transform: @escaping @MainActor (inout Transaction) -> Void) -> some View {
        modifier(_TransactionModifier(transform: transform))
    }

    public func transaction<V: Equatable>(value: V, _ transform: @escaping @MainActor (inout Transaction) -> Void) -> some View {
        modifier(_TransactionModifier(transform: transform))
    }
}

// MARK: - Transitions

/// How a view enters/leaves when inserted/removed in an animated transaction. Applied by the
/// renderer to the platform views of the inserted/removed subtree.
public struct AnyTransition: Sendable {
    /// Presentation offsets applied in the "active" (not yet inserted / being removed) state.
    struct Effect: Sendable, Equatable {
        var opacity: Double = 1
        var scale: CGSize = CGSize(width: 1, height: 1)
        var scaleAnchor: UnitPoint = .center
        var offset: CGSize = .zero
        /// Offset as a fraction of the view's own size (move/slide).
        var relativeOffset: CGSize = .zero
        var rotationDegrees: Double = 0

        func combined(with other: Effect) -> Effect {
            Effect(
                opacity: opacity * other.opacity,
                scale: CGSize(width: scale.width * other.scale.width, height: scale.height * other.scale.height),
                scaleAnchor: other.scale == CGSize(width: 1, height: 1) ? scaleAnchor : other.scaleAnchor,
                offset: CGSize(width: offset.width + other.offset.width, height: offset.height + other.offset.height),
                relativeOffset: CGSize(width: relativeOffset.width + other.relativeOffset.width, height: relativeOffset.height + other.relativeOffset.height),
                rotationDegrees: rotationDegrees + other.rotationDegrees
            )
        }

        static let identity = Effect()
    }

    var insertion: Effect
    var removal: Effect
    var animation: Animation?

    init(insertion: Effect, removal: Effect) {
        self.insertion = insertion
        self.removal = removal
    }

    init(_ effect: Effect) { self.init(insertion: effect, removal: effect) }

    public static let identity = AnyTransition(.identity)
    public static let opacity = AnyTransition(Effect(opacity: 0))
    public static let scale = AnyTransition.scale(scale: 0)
    public static let slide = AnyTransition(insertion: Effect(relativeOffset: CGSize(width: -1, height: 0)), removal: Effect(relativeOffset: CGSize(width: 1, height: 0)))

    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition {
        AnyTransition(Effect(scale: CGSize(width: scale, height: scale), scaleAnchor: anchor))
    }

    public static func move(edge: Edge) -> AnyTransition {
        let offset: CGSize
        switch edge {
        case .top: offset = CGSize(width: 0, height: -1)
        case .bottom: offset = CGSize(width: 0, height: 1)
        case .leading: offset = CGSize(width: -1, height: 0)
        case .trailing: offset = CGSize(width: 1, height: 0)
        }
        return AnyTransition(Effect(relativeOffset: offset))
    }

    public static func push(from edge: Edge) -> AnyTransition {
        let inserted = move(edge: edge).insertion
        let opposite: Edge = [.top: .bottom, .bottom: .top, .leading: .trailing, .trailing: .leading][edge]!
        var removal = move(edge: opposite).removal
        removal.opacity = 0
        return AnyTransition(insertion: inserted, removal: removal)
    }

    /// Blur-and-scale replace; blur is not rendered (Apple-specific effect), so it fades and scales.
    public static var blurReplace: AnyTransition { .opacity.combined(with: .scale(scale: 0.8)) }
    public static func blurReplace(_ config: BlurReplaceTransition.Configuration = .downUp) -> AnyTransition { blurReplace }

    public static func offset(_ offset: CGSize) -> AnyTransition { AnyTransition(Effect(offset: offset)) }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition { .offset(CGSize(width: x, height: y)) }

    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        AnyTransition(insertion: insertion.insertion, removal: removal.removal)
    }

    public func combined(with other: AnyTransition) -> AnyTransition {
        AnyTransition(insertion: insertion.combined(with: other.insertion), removal: removal.combined(with: other.removal))
    }

    public func animation(_ animation: Animation?) -> AnyTransition {
        var copy = self
        copy.animation = animation
        return copy
    }
}

extension AnyTransition: _GraphComparable {
    public static func _isIdentical(_ lhs: AnyTransition, _ rhs: AnyTransition) -> Bool {
        lhs.insertion == rhs.insertion && lhs.removal == rhs.removal && lhs.animation == rhs.animation
    }
}

public struct _TransitionModifier: ViewModifier {
    let transition: AnyTransition
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let renderer = inputs.host.renderer
        let group = renderer.makeGroup(path: inputs.path)
        group.transition = AnyAttribute.withoutDependencies { modifier.attribute.value.transition }
        renderer.append(group, to: inputs.render.parent)
        inputs.subgraph.onDestroy { renderer.remove(group) }
        var childInputs = inputs
        childInputs.render = _RenderInputs(parent: group, origin: inputs.render.origin)
        return body(childInputs)
    }
}

extension View {
    public func transition(_ transition: AnyTransition) -> some View {
        modifier(_TransitionModifier(transition: transition))
    }
}

public struct BlurReplaceTransition: Sendable {
    public enum Configuration: Sendable { case downUp, upUp }
}
