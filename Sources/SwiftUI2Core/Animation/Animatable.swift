import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public protocol VectorArithmetic: AdditiveArithmetic {
    mutating func scale(by rhs: Double)
    var magnitudeSquared: Double { get }
}

extension VectorArithmetic {
    public func scaled(by rhs: Double) -> Self {
        var copy = self
        copy.scale(by: rhs)
        return copy
    }

    /// `from + (to - from) * progress`.
    static func interpolate(_ from: Self, _ to: Self, _ progress: Double) -> Self {
        from + (to - from).scaled(by: progress)
    }
}

extension Double: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= rhs }
    public var magnitudeSquared: Double { self * self }
}

extension Float: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= Float(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

extension CGFloat: VectorArithmetic {
    public mutating func scale(by rhs: Double) { self *= CGFloat(rhs) }
    public var magnitudeSquared: Double { Double(self * self) }
}

public struct EmptyAnimatableData: VectorArithmetic, Sendable {
    public init() {}
    public static var zero: EmptyAnimatableData { EmptyAnimatableData() }
    public static func + (lhs: Self, rhs: Self) -> Self { lhs }
    public static func - (lhs: Self, rhs: Self) -> Self { lhs }
    public mutating func scale(by rhs: Double) {}
    public var magnitudeSquared: Double { 0 }
}

public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    public static var zero: Self { Self(.zero, .zero) }
    public static func + (lhs: Self, rhs: Self) -> Self { Self(lhs.first + rhs.first, lhs.second + rhs.second) }
    public static func - (lhs: Self, rhs: Self) -> Self { Self(lhs.first - rhs.first, lhs.second - rhs.second) }
    public mutating func scale(by rhs: Double) {
        first.scale(by: rhs)
        second.scale(by: rhs)
    }
    public var magnitudeSquared: Double { first.magnitudeSquared + second.magnitudeSquared }
}

/// Types whose `animatableData` the graph interpolates frame by frame (body re-evaluated per
/// frame, exactly like SwiftUI).
@MainActor @preconcurrency
public protocol Animatable {
    associatedtype AnimatableData: VectorArithmetic
    var animatableData: AnimatableData { get set }
}

extension Animatable where AnimatableData == EmptyAnimatableData {
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }
}

extension Animatable where Self: VectorArithmetic {
    public var animatableData: Self {
        get { self }
        set { self = newValue }
    }
}

extension CGPoint: Animatable {
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(x, y) }
        set { (x, y) = (newValue.first, newValue.second) }
    }
}

extension CGSize: Animatable {
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set { (width, height) = (newValue.first, newValue.second) }
    }
}

extension CGRect: Animatable {
    public var animatableData: AnimatablePair<CGPoint.AnimatableData, CGSize.AnimatableData> {
        get { AnimatablePair(origin.animatableData, size.animatableData) }
        set { (origin.animatableData, size.animatableData) = (newValue.first, newValue.second) }
    }
}

extension Angle: Animatable {
    public var animatableData: Double {
        get { radians }
        set { radians = newValue }
    }
}

/// A modifier whose `animatableData` is interpolated (deprecated in SwiftUI but still common).
public protocol AnimatableModifier: Animatable, ViewModifier {}

// MARK: - Runtime support

@MainActor
private final class AnimatorState<Data: VectorArithmetic> {
    var target: Data?
    var presented: Data?
    var from: Data?
    var animation: Animation?
    var start: Double = 0
    var isRunning: Bool { animation != nil }
}

/// If `V` is `Animatable` with non-empty data, returns an attribute that interpolates the value's
/// `animatableData` whenever it changes in an animated transaction.
@MainActor
func animatedIfNeeded<V>(_ value: Attribute<V>, host: ViewGraph, scope: AnimationScope?, subgraph: Subgraph) -> Attribute<V> {
    guard let animatable = V.self as? any Animatable.Type else { return value }
    func open<A: Animatable>(_: A.Type) -> Attribute<V> {
        guard A.AnimatableData.self != EmptyAnimatableData.self else { return value }
        let typed = unsafeBitCast(value, to: Attribute<A>.self)
        return unsafeBitCast(makeAnimator(typed, host: host, scope: scope, subgraph: subgraph), to: Attribute<V>.self)
    }
    return open(animatable)
}

@MainActor
private func makeAnimator<A: Animatable>(_ source: Attribute<A>, host: ViewGraph, scope: AnimationScope?, subgraph: Subgraph) -> Attribute<A> {
    let state = AnimatorState<A.AnimatableData>()
    subgraph.onDestroy { [weak host] in
        if state.isRunning { host?.animatorStopped() }
        state.animation = nil
    }
    let attribute = Attribute<A>(subgraph) {
        var value = source.value
        let target = value.animatableData
        defer { state.target = target }
        guard let previous = state.target else {
            state.presented = target
            return value
        }
        if previous != target {
            let transaction = scope?.resolve(host.currentTransaction) ?? host.currentTransaction
            if let animation = transaction.animation, !transaction.disablesAnimations {
                if !state.isRunning { host.animatorStarted() }
                state.from = state.presented ?? previous
                state.animation = animation
                state.start = host.now
            } else {
                if state.isRunning { host.animatorStopped() }
                state.animation = nil
                state.presented = target
            }
        }
        guard let animation = state.animation, let from = state.from else { return value }
        let time = host.animationTime.value
        let (progress, finished) = animation.sample(at: time - state.start)
        if finished {
            state.animation = nil
            state.presented = target
            host.animatorStopped()
            return value
        }
        let presented = A.AnimatableData.interpolate(from, target, progress)
        state.presented = presented
        value.animatableData = presented
        return value
    }
    attribute.label = "animator \(A.self)"
    return attribute
}
