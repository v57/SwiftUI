import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Spring

/// A spring model (`Spring(duration:bounce:)`, `Spring(response:dampingRatio:)`).
public struct Spring: Hashable, Sendable {
    public var response: Double
    public var dampingRatio: Double

    public init(duration: Double = 0.5, bounce: Double = 0) {
        response = max(duration, 0.01)
        dampingRatio = bounce >= 0 ? 1 - bounce : 1 / (1 + bounce)
    }

    public init(response: Double, dampingRatio: Double) {
        self.response = max(response, 0.01)
        self.dampingRatio = max(dampingRatio, 0)
    }

    public init(mass: Double = 1, stiffness: Double, damping: Double, allowOverDamping: Bool = false) {
        let omega = (stiffness / mass).squareRoot()
        response = 2 * .pi / max(omega, 0.001)
        let ratio = damping / (2 * (stiffness * mass).squareRoot())
        dampingRatio = allowOverDamping ? ratio : min(ratio, 1)
    }

    public static let smooth = Spring(duration: 0.5, bounce: 0)
    public static let snappy = Spring(duration: 0.5, bounce: 0.15)
    public static let bouncy = Spring(duration: 0.5, bounce: 0.3)
    public static func smooth(duration: Double = 0.5, extraBounce: Double = 0) -> Spring { Spring(duration: duration, bounce: extraBounce) }
    public static func snappy(duration: Double = 0.5, extraBounce: Double = 0) -> Spring { Spring(duration: duration, bounce: 0.15 + extraBounce) }
    public static func bouncy(duration: Double = 0.5, extraBounce: Double = 0) -> Spring { Spring(duration: duration, bounce: 0.3 + extraBounce) }

    public var duration: Double { response }
    public var bounce: Double { dampingRatio <= 1 ? 1 - dampingRatio : 1 / dampingRatio - 1 }
    public var mass: Double { 1 }
    public var stiffness: Double { pow(2 * .pi / response, 2) }
    public var damping: Double { 4 * .pi * dampingRatio / response }

    /// Time until the spring is within 0.1% of its target.
    public var settlingDuration: Double { Animation.springSettlingTime(response: response, damping: dampingRatio) }

    /// Normalized position (0 → 1, may overshoot) after `time` seconds.
    public func value(fraction time: Double) -> Double {
        let omega = 2 * .pi / response
        if dampingRatio < 1 {
            let wd = omega * (1 - dampingRatio * dampingRatio).squareRoot()
            let envelope = exp(-dampingRatio * omega * time)
            return 1 - envelope * (cos(wd * time) + (dampingRatio * omega / wd) * sin(wd * time))
        }
        return 1 - exp(-omega * time) * (1 + omega * time)
    }

    public func value<V: VectorArithmetic>(target: V, initialVelocity: V = .zero, time: Double) -> V {
        target.scaled(by: value(fraction: time))
    }
}

extension Animation {
    public static func spring(_ spring: Spring, blendDuration: Double = 0) -> Animation {
        Animation.spring(response: spring.response, dampingFraction: spring.dampingRatio, blendDuration: blendDuration)
    }

}

// MARK: - UnitCurve

/// A timing curve over `0...1` (`UnitCurve.easeInOut`, `.bezier(startControlPoint:endControlPoint:)`).
public struct UnitCurve: Hashable, Sendable {
    let p1: CGPoint
    let p2: CGPoint
    let isLinear: Bool

    public static func bezier(startControlPoint: UnitPoint, endControlPoint: UnitPoint) -> UnitCurve {
        UnitCurve(p1: CGPoint(x: startControlPoint.x, y: startControlPoint.y), p2: CGPoint(x: endControlPoint.x, y: endControlPoint.y), isLinear: false)
    }

    public static let linear = UnitCurve(p1: .zero, p2: CGPoint(x: 1, y: 1), isLinear: true)
    public static let easeIn = bezier(startControlPoint: UnitPoint(x: 0.42, y: 0), endControlPoint: UnitPoint(x: 1, y: 1))
    public static let easeOut = bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))
    public static let easeInOut = bezier(startControlPoint: UnitPoint(x: 0.42, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))
    public static let circularEaseIn = bezier(startControlPoint: UnitPoint(x: 0.6, y: 0.04), endControlPoint: UnitPoint(x: 0.98, y: 0.335))
    public static let circularEaseOut = bezier(startControlPoint: UnitPoint(x: 0.075, y: 0.82), endControlPoint: UnitPoint(x: 0.165, y: 1))
    public static let circularEaseInOut = bezier(startControlPoint: UnitPoint(x: 0.785, y: 0.135), endControlPoint: UnitPoint(x: 0.15, y: 0.86))

    public func value(at progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return isLinear ? t : Animation.cubicBezier(t, p1.x, p1.y, p2.x, p2.y)
    }

    public var inverse: UnitCurve { UnitCurve(p1: CGPoint(x: p1.y, y: p1.x), p2: CGPoint(x: p2.y, y: p2.x), isLinear: isLinear) }
}

extension Animation {
    public static func timingCurve(_ curve: UnitCurve, duration: Double) -> Animation {
        curve.isLinear ? .linear(duration: duration) : .timingCurve(curve.p1.x, curve.p1.y, curve.p2.x, curve.p2.y, duration: duration)
    }
}

// MARK: - Scalar Animatable conformances (as in SwiftUI)

extension Double: Animatable {}
extension Float: Animatable {}
extension CGFloat: Animatable {}

// MARK: - Keyframe content

/// One keyframe segment of a track, in the value's animatable data space.
public struct _KeyframeSegment<Value: Animatable> {
    enum Kind {
        case linear(UnitCurve)
        case spring(Spring)
        case cubic(start: Value.AnimatableData?, end: Value.AnimatableData?)
        case move
    }
    let kind: Kind
    let target: Value.AnimatableData
    let duration: Double?
}

/// Content of a keyframe track (keyframes and groups of them).
public protocol KeyframeTrackContent<Value> {
    associatedtype Value: Animatable
    var _segments: [_KeyframeSegment<Value>] { get }
}

public struct LinearKeyframe<Value: Animatable>: KeyframeTrackContent {
    let to: Value
    let duration: Double
    let timingCurve: UnitCurve
    public init(_ to: Value, duration: Double, timingCurve: UnitCurve = .linear) {
        self.to = to
        self.duration = duration
        self.timingCurve = timingCurve
    }
    public var _segments: [_KeyframeSegment<Value>] { [_KeyframeSegment(kind: .linear(timingCurve), target: to.animatableData, duration: duration)] }
}

public struct SpringKeyframe<Value: Animatable>: KeyframeTrackContent {
    let to: Value
    let duration: Double?
    let spring: Spring
    public init(_ to: Value, duration: Double? = nil, spring: Spring = Spring(), startVelocity: Value? = nil) {
        self.to = to
        self.duration = duration
        self.spring = spring
    }
    public var _segments: [_KeyframeSegment<Value>] { [_KeyframeSegment(kind: .spring(spring), target: to.animatableData, duration: duration)] }
}

public struct CubicKeyframe<Value: Animatable>: KeyframeTrackContent {
    let to: Value
    let duration: Double
    let startVelocity: Value?
    let endVelocity: Value?
    public init(_ to: Value, duration: Double, startVelocity: Value? = nil, endVelocity: Value? = nil) {
        self.to = to
        self.duration = duration
        self.startVelocity = startVelocity
        self.endVelocity = endVelocity
    }
    public var _segments: [_KeyframeSegment<Value>] {
        [_KeyframeSegment(kind: .cubic(start: startVelocity?.animatableData, end: endVelocity?.animatableData), target: to.animatableData, duration: duration)]
    }
}

public struct MoveKeyframe<Value: Animatable>: KeyframeTrackContent {
    let to: Value
    public init(_ to: Value) { self.to = to }
    public var _segments: [_KeyframeSegment<Value>] { [_KeyframeSegment(kind: .move, target: to.animatableData, duration: 0)] }
}

/// A sequence of keyframes built by `KeyframeTrackContentBuilder`.
public struct _KeyframeSequence<Value: Animatable>: KeyframeTrackContent {
    public let _segments: [_KeyframeSegment<Value>]
}

@resultBuilder
public enum KeyframeTrackContentBuilder<Value: Animatable> {
    public static func buildExpression<K: KeyframeTrackContent>(_ keyframe: K) -> _KeyframeSequence<Value> where K.Value == Value {
        _KeyframeSequence(_segments: keyframe._segments)
    }
    public static func buildBlock(_ parts: _KeyframeSequence<Value>...) -> _KeyframeSequence<Value> {
        _KeyframeSequence(_segments: parts.flatMap(\._segments))
    }
    public static func buildArray(_ parts: [_KeyframeSequence<Value>]) -> _KeyframeSequence<Value> {
        _KeyframeSequence(_segments: parts.flatMap(\._segments))
    }
    public static func buildOptional(_ part: _KeyframeSequence<Value>?) -> _KeyframeSequence<Value> { part ?? _KeyframeSequence(_segments: []) }
    public static func buildEither(first: _KeyframeSequence<Value>) -> _KeyframeSequence<Value> { first }
    public static func buildEither(second: _KeyframeSequence<Value>) -> _KeyframeSequence<Value> { second }
    public static func buildLimitedAvailability(_ part: _KeyframeSequence<Value>) -> _KeyframeSequence<Value> { part }
}

// MARK: - Tracks and timelines

/// Evaluates one property of a keyframed value over time.
public struct _KeyframeTrackEvaluator<Root> {
    let duration: Double
    let apply: (inout Root, Double) -> Void
}

/// Keyframes for a whole value: one or more tracks.
public protocol Keyframes<Value> {
    associatedtype Value
    var _tracks: [_KeyframeTrackEvaluator<Value>] { get }
}

public struct KeyframeTrack<Root, Value: Animatable, Content: KeyframeTrackContent>: Keyframes where Content.Value == Value {
    let keyPath: WritableKeyPath<Root, Value>
    let content: Content

    public init(_ keyPath: WritableKeyPath<Root, Value>, @KeyframeTrackContentBuilder<Value> content: () -> Content) {
        self.keyPath = keyPath
        self.content = content()
    }

    public var _tracks: [_KeyframeTrackEvaluator<Root>] {
        let keyPath = self.keyPath
        let segments = content._segments
        let durations = segments.map(Self.duration(of:))
        return [_KeyframeTrackEvaluator(duration: durations.reduce(0, +)) { root, time in
            var value = root[keyPath: keyPath]
            value.animatableData = Self.evaluate(segments, durations: durations, from: value.animatableData, at: time)
            root[keyPath: keyPath] = value
        }]
    }

    static func duration(of segment: _KeyframeSegment<Value>) -> Double {
        if let duration = segment.duration { return max(duration, 0) }
        if case .spring(let spring) = segment.kind { return spring.settlingDuration }
        return 0
    }

    /// Value of the track `time` seconds in, starting from `initial`.
    static func evaluate(_ segments: [_KeyframeSegment<Value>], durations: [Double], from initial: Value.AnimatableData, at time: Double) -> Value.AnimatableData {
        var start = initial
        var elapsed = 0.0
        for (index, segment) in segments.enumerated() {
            let duration = durations[index]
            let local = time - elapsed
            if local < duration, duration > 0 {
                let t = max(local, 0)
                switch segment.kind {
                case .move:
                    return segment.target
                case .linear(let curve):
                    return Value.AnimatableData.interpolate(start, segment.target, curve.value(at: t / duration))
                case .spring(let spring):
                    return Value.AnimatableData.interpolate(start, segment.target, spring.value(fraction: t))
                case let .cubic(startVelocity, endVelocity):
                    // Catmull-Rom tangents from the neighbouring keyframes unless velocities are given.
                    let previous = index > 0 ? (index > 1 ? segments[index - 2].target : initial) : start
                    let next = index + 1 < segments.count ? segments[index + 1].target : segment.target
                    let m0 = startVelocity?.scaled(by: duration) ?? (segment.target - previous).scaled(by: 0.5)
                    let m1 = endVelocity?.scaled(by: duration) ?? (next - start).scaled(by: 0.5)
                    let s = t / duration
                    let s2 = s * s, s3 = s2 * s
                    return start.scaled(by: 2 * s3 - 3 * s2 + 1) + m0.scaled(by: s3 - 2 * s2 + s)
                        + segment.target.scaled(by: -2 * s3 + 3 * s2) + m1.scaled(by: s3 - s2)
                }
            }
            start = segment.target
            elapsed += duration
        }
        return start
    }
}

extension KeyframeTrack where Root == Value {
    public init(@KeyframeTrackContentBuilder<Value> content: () -> Content) {
        self.init(\.self, content: content)
    }
}

/// Tracks combined by `KeyframesBuilder`.
public struct _KeyframeTracks<Value>: Keyframes {
    public let _tracks: [_KeyframeTrackEvaluator<Value>]
}

@resultBuilder
public enum KeyframesBuilder<Value> {
    public static func buildExpression<K: Keyframes>(_ keyframes: K) -> _KeyframeTracks<Value> where K.Value == Value {
        _KeyframeTracks(_tracks: keyframes._tracks)
    }
    public static func buildBlock(_ parts: _KeyframeTracks<Value>...) -> _KeyframeTracks<Value> {
        _KeyframeTracks(_tracks: parts.flatMap(\._tracks))
    }
    public static func buildArray(_ parts: [_KeyframeTracks<Value>]) -> _KeyframeTracks<Value> {
        _KeyframeTracks(_tracks: parts.flatMap(\._tracks))
    }
    public static func buildOptional(_ part: _KeyframeTracks<Value>?) -> _KeyframeTracks<Value> { part ?? _KeyframeTracks(_tracks: []) }
    public static func buildEither(first: _KeyframeTracks<Value>) -> _KeyframeTracks<Value> { first }
    public static func buildEither(second: _KeyframeTracks<Value>) -> _KeyframeTracks<Value> { second }
    public static func buildLimitedAvailability(_ part: _KeyframeTracks<Value>) -> _KeyframeTracks<Value> { part }
}

extension KeyframesBuilder where Value: Animatable {
    /// Keyframes written directly (without a track) animate the whole value.
    public static func buildExpression<K: KeyframeTrackContent>(_ keyframes: K) -> _KeyframeTracks<Value> where K.Value == Value {
        _KeyframeTracks(_tracks: KeyframeTrack(\Value.self) { keyframes }._tracks)
    }
}

/// Evaluates keyframes at arbitrary times (`KeyframeTimeline(initialValue:) { ... }`).
public struct KeyframeTimeline<Value> {
    let initialValue: Value
    let tracks: [_KeyframeTrackEvaluator<Value>]

    public init<Content: Keyframes>(initialValue: Value, @KeyframesBuilder<Value> content: () -> Content) where Content.Value == Value {
        self.initialValue = initialValue
        self.tracks = content()._tracks
    }

    init(initialValue: Value, tracks: [_KeyframeTrackEvaluator<Value>]) {
        self.initialValue = initialValue
        self.tracks = tracks
    }

    /// The longest track's duration.
    public var duration: Double { tracks.map(\.duration).max() ?? 0 }

    public func value(time: Double) -> Value {
        var value = initialValue
        for track in tracks { track.apply(&value, time) }
        return value
    }

    public func value(progress: Double) -> Value { value(time: progress * duration) }
}

// MARK: - KeyframeAnimator

/// Type-erased equatable trigger.
struct _AnyTrigger {
    let value: Any
    let isEqual: (Any) -> Bool
    init<T: Equatable>(_ value: T) {
        self.value = value
        self.isEqual = { ($0 as? T) == value }
    }
}

@MainActor
final class _KeyframeAnimatorState<Value> {
    var trigger: _AnyTrigger?
    var timeline: KeyframeTimeline<Value>?
    var start: Double = 0
    var isRunning = false
    var current: Value?
}

/// Plays keyframes when its trigger changes (or repeatedly), passing the animated value to its
/// content every frame.
public struct KeyframeAnimator<Value, KeyframePath: Keyframes, Content: View>: View where KeyframePath.Value == Value {
    let initialValue: Value
    let trigger: _AnyTrigger?
    let repeating: Bool
    let content: (Value) -> Content
    let keyframes: (Value) -> KeyframePath

    public init(initialValue: Value, repeating: Bool = true, @ViewBuilder content: @escaping (Value) -> Content, @KeyframesBuilder<Value> keyframes: @escaping (Value) -> KeyframePath) {
        self.initialValue = initialValue
        self.trigger = nil
        self.repeating = repeating
        self.content = content
        self.keyframes = keyframes
    }

    public init(initialValue: Value, trigger: some Equatable, @ViewBuilder content: @escaping (Value) -> Content, @KeyframesBuilder<Value> keyframes: @escaping (Value) -> KeyframePath) {
        self.initialValue = initialValue
        self.trigger = _AnyTrigger(trigger)
        self.repeating = false
        self.content = content
        self.keyframes = keyframes
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "KeyframeAnimator")
        let host = inputs.host
        let state = _KeyframeAnimatorState<Value>()
        inputs.subgraph.onDestroy { [weak host] in
            if state.isRunning { host?.animatorStopped() }
            state.isRunning = false
        }
        let content = makeObservedAttribute(inputs.subgraph, of: Content.self) {
            let animator = view.attribute.value
            @MainActor func begin() {
                state.timeline = KeyframeTimeline(initialValue: animator.initialValue, tracks: animator.keyframes(state.current ?? animator.initialValue)._tracks)
                state.start = host.now
                if !state.isRunning, (state.timeline?.duration ?? 0) > 0 {
                    state.isRunning = true
                    host.animatorStarted()
                }
            }
            if let trigger = animator.trigger {
                if let previous = state.trigger {
                    if !previous.isEqual(trigger.value) {
                        state.trigger = trigger
                        begin()
                    }
                } else {
                    state.trigger = trigger
                }
            } else if animator.repeating, state.timeline == nil {
                begin()
            }
            var value = animator.initialValue
            if state.isRunning, let timeline = state.timeline {
                let elapsed = max(0, host.animationTime.value - state.start)
                let duration = timeline.duration
                if animator.repeating {
                    value = timeline.value(time: elapsed.truncatingRemainder(dividingBy: duration))
                } else if elapsed >= duration {
                    state.isRunning = false
                    host.animatorStopped()
                } else {
                    value = timeline.value(time: elapsed)
                }
            }
            state.current = value
            return animator.content(value)
        }
        return Content._makeView(view: _GraphValue(content), inputs: inputs)
    }
}

extension View {
    public func keyframeAnimator<Value, Content: View, Path: Keyframes>(
        initialValue: Value, repeating: Bool = true,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Value) -> Content,
        @KeyframesBuilder<Value> keyframes: @escaping (Value) -> Path
    ) -> some View where Path.Value == Value {
        let base = self
        return KeyframeAnimator(initialValue: initialValue, repeating: repeating, content: { content(PlaceholderContentView(content: base), $0) }, keyframes: keyframes)
    }

    public func keyframeAnimator<Value, Content: View, Path: Keyframes>(
        initialValue: Value, trigger: some Equatable,
        @ViewBuilder content: @escaping (PlaceholderContentView<Self>, Value) -> Content,
        @KeyframesBuilder<Value> keyframes: @escaping (Value) -> Path
    ) -> some View where Path.Value == Value {
        let base = self
        return KeyframeAnimator(initialValue: initialValue, trigger: trigger, content: { content(PlaceholderContentView(content: base), $0) }, keyframes: keyframes)
    }
}

// MARK: - PhaseAnimator

/// Cycles through phases, animating each change (`PhaseAnimator([0, 1]) { phase in ... }`).
public struct PhaseAnimator<Phase: Equatable, Content: View>: View {
    let phases: [Phase]
    let trigger: _AnyTrigger?
    let content: (Phase) -> Content
    let animation: (Phase) -> Animation?

    public init(_ phases: some Sequence<Phase>, @ViewBuilder content: @escaping (Phase) -> Content, animation: @escaping (Phase) -> Animation? = { _ in .default }) {
        self.phases = Array(phases)
        self.trigger = nil
        self.content = content
        self.animation = animation
    }

    public init(_ phases: some Sequence<Phase>, trigger: some Equatable, @ViewBuilder content: @escaping (Phase) -> Content, animation: @escaping (Phase) -> Animation? = { _ in .default }) {
        self.phases = Array(phases)
        self.trigger = _AnyTrigger(trigger)
        self.content = content
        self.animation = animation
    }

    public var body: some View {
        let content = self.content
        _PhaseAnimatorView(base: EmptyView(), phases: phases, trigger: _TriggerToken(trigger), loops: trigger == nil,
                           content: { _, phase in content(phase) }, animation: animation)
    }
}

/// Equatable wrapper of an optional type-erased trigger.
struct _TriggerToken: Equatable {
    let trigger: _AnyTrigger?
    init(_ trigger: _AnyTrigger?) { self.trigger = trigger }
    static func == (lhs: _TriggerToken, rhs: _TriggerToken) -> Bool {
        switch (lhs.trigger, rhs.trigger) {
        case (nil, nil): return true
        case let (l?, r?): return l.isEqual(r.value)
        default: return false
        }
    }
}
