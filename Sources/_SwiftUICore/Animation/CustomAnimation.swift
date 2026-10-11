import Foundation

/// A custom animation curve: returns the current value of `value` (the change being animated)
/// `time` seconds in, or nil when finished.
public protocol CustomAnimation: Hashable, Sendable {
    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V?
    func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V?
    func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>) -> Bool
}

extension CustomAnimation {
    public func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? { nil }
    public func shouldMerge<V: VectorArithmetic>(previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>) -> Bool { false }
}

/// Per-animation storage for custom animations.
public protocol AnimationStateKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct AnimationState<Value: VectorArithmetic> {
    var storage: [ObjectIdentifier: Any] = [:]
    public init() {}
    public subscript<K: AnimationStateKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

public struct AnimationContext<Value: VectorArithmetic> {
    public var state: AnimationState<Value>
    public var isLogicallyComplete: Bool
    public var environment: EnvironmentValues { EnvironmentValues() }

    init() {
        state = AnimationState()
        isLogicallyComplete = false
    }
}

/// Type-erased custom animation (compared by value).
struct _AnyCustomAnimation: Hashable, @unchecked Sendable {
    let base: AnyHashable
    let sample: (TimeInterval) -> Double?

    init<A: CustomAnimation>(_ animation: A) {
        base = AnyHashable(animation)
        sample = { time in
            var context = AnimationContext<Double>()
            return animation.animate(value: 1.0, time: time, context: &context)
        }
    }

    /// Progress of a unit change at `time` (nil when finished).
    func progress(at time: TimeInterval) -> Double? { sample(time) }

    /// When the curve finishes (searched up to 10 s); used to schedule follow-up work.
    var estimatedDuration: Double {
        var time = 0.0
        while time < 10, sample(time) != nil { time += 1.0 / 60 }
        return max(time, 1.0 / 60)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.base == rhs.base }
    func hash(into hasher: inout Hasher) { hasher.combine(base) }
}
