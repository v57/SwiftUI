import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Describes how a change is animated. Sampled by the renderer (frames, colors, opacity, paths,
/// transitions) and by `Animatable` views (their `animatableData`).
public struct Animation: Hashable, Sendable, CustomStringConvertible {
    enum Curve: Hashable, Sendable {
        case linear
        case bezier(Double, Double, Double, Double)
        case spring(response: Double, dampingFraction: Double)
        case custom(_AnyCustomAnimation)
    }

    let curve: Curve
    let duration: Double
    var delay: Double = 0
    var speed: Double = 1
    var repeatCount: Int? = 1 // nil = forever
    var autoreverses = false

    init(curve: Curve, duration: Double) {
        self.curve = curve
        self.duration = duration
    }

    public static let `default` = Animation.easeInOut
    public static let linear = Animation(curve: .linear, duration: 0.35)
    public static let easeIn = Animation(curve: .bezier(0.42, 0, 1, 1), duration: 0.35)
    public static let easeOut = Animation(curve: .bezier(0, 0, 0.58, 1), duration: 0.35)
    public static let easeInOut = Animation(curve: .bezier(0.42, 0, 0.58, 1), duration: 0.35)
    public static let spring = Animation.spring(response: 0.5, dampingFraction: 0.825)
    public static let interactiveSpring = Animation.spring(response: 0.15, dampingFraction: 0.86)
    public static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.7)
    public static let smooth = Animation.spring(response: 0.5, dampingFraction: 1)
    public static let snappy = Animation.spring(response: 0.5, dampingFraction: 0.85)

    public static func linear(duration: Double) -> Animation { Animation(curve: .linear, duration: duration) }
    public static func easeIn(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 1, 1), duration: duration) }
    public static func easeOut(duration: Double) -> Animation { Animation(curve: .bezier(0, 0, 0.58, 1), duration: duration) }
    public static func easeInOut(duration: Double) -> Animation { Animation(curve: .bezier(0.42, 0, 0.58, 1), duration: duration) }
    public static func timingCurve(_ c0x: Double, _ c0y: Double, _ c1x: Double, _ c1y: Double, duration: Double = 0.35) -> Animation {
        Animation(curve: .bezier(c0x, c0y, c1x, c1y), duration: duration)
    }

    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825, blendDuration: Double = 0) -> Animation {
        Animation(curve: .spring(response: max(response, 0.01), dampingFraction: max(dampingFraction, 0)), duration: springSettlingTime(response: response, damping: dampingFraction))
    }

    public static func spring(duration: Double = 0.5, bounce: Double = 0, blendDuration: Double = 0) -> Animation {
        spring(response: duration, dampingFraction: bounce >= 0 ? 1 - bounce : 1 / (1 + bounce))
    }

    public static func bouncy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: 0.3 + extraBounce) }
    public static func smooth(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: extraBounce) }
    public static func snappy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { spring(duration: duration, bounce: 0.15 + extraBounce) }

    static func _interpolatingSpring(stiffness: Double, damping: Double, mass: Double = 1) -> Animation {
        let omega = (stiffness / mass).squareRoot()
        let response = 2 * .pi / max(omega, 0.001)
        let zeta = damping / (2 * (stiffness * mass).squareRoot())
        return spring(response: response, dampingFraction: zeta)
    }

    public static func interpolatingSpring(mass: Double = 1, stiffness: Double, damping: Double, initialVelocity: Double = 0) -> Animation {
        _interpolatingSpring(stiffness: stiffness, damping: damping, mass: mass)
    }

    public static func interpolatingSpring(duration: Double = 0.5, bounce: Double = 0, initialVelocity: Double = 0) -> Animation {
        spring(duration: duration, bounce: bounce)
    }

    public static var interpolatingSpring: Animation { interpolatingSpring() }

    public static func interactiveSpring(response: Double = 0.15, dampingFraction: Double = 0.86, blendDuration: Double = 0.25) -> Animation {
        spring(response: response, dampingFraction: dampingFraction)
    }

    public func delay(_ delay: Double) -> Animation {
        var copy = self
        copy.delay = delay
        return copy
    }

    public func speed(_ speed: Double) -> Animation {
        var copy = self
        copy.speed = max(speed, 0.0001)
        return copy
    }

    public func repeatCount(_ count: Int, autoreverses: Bool = true) -> Animation {
        var copy = self
        copy.repeatCount = max(count, 1)
        copy.autoreverses = autoreverses
        return copy
    }

    public func repeatForever(autoreverses: Bool = true) -> Animation {
        var copy = self
        copy.repeatCount = nil
        copy.autoreverses = autoreverses
        return copy
    }

    public var description: String { "Animation(\(curve), \(duration)s)" }

    /// Seconds one run of the animation takes (delay excluded, speed applied).
    public var _effectiveDuration: Double { duration / speed }

    static func springSettlingTime(response: Double, damping: Double) -> Double {
        let omega = 2 * .pi / max(response, 0.01)
        let zeta = max(damping, 0.01)
        return min(max(-log(0.001) / (zeta * omega), response), 10)
    }

    /// An animation driven by a `CustomAnimation` (sampled as progress of a unit value).
    public init<A: CustomAnimation>(_ base: A) {
        self.init(curve: .custom(_AnyCustomAnimation(base)), duration: _AnyCustomAnimation(base).estimatedDuration)
    }

    /// Progress (0…1, may overshoot for springs) at `elapsed` seconds after start.
    func sample(at elapsed: Double) -> (progress: Double, finished: Bool) {
        let time = (elapsed - delay) * speed
        if time <= 0 { return (0, false) }
        if case .custom(let custom) = curve {
            guard let progress = custom.progress(at: time) else { return (1, true) }
            return (progress, false)
        }
        guard duration > 0 else { return (1, true) }
        var iteration = (time / duration).rounded(.down)
        var local = time - iteration * duration
        if let repeatCount, iteration >= Double(repeatCount) {
            iteration = Double(repeatCount - 1)
            local = duration
        }
        var fraction = curveValue(local / duration)
        if autoreverses, Int(iteration) % 2 == 1 { fraction = 1 - fraction }
        let finished = repeatCount.map { time >= duration * Double($0) } ?? false
        if finished {
            let endsReversed = autoreverses && (repeatCount ?? 1) % 2 == 0
            return (endsReversed ? 0 : 1, true)
        }
        return (fraction, false)
    }

    private func curveValue(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch curve {
        case .linear:
            return t
        case let .bezier(x1, y1, x2, y2):
            return Animation.cubicBezier(t, x1, y1, x2, y2)
        case .custom(let custom):
            return custom.progress(at: t * duration) ?? 1
        case let .spring(response, damping):
            let elapsed = t * duration
            let omega = 2 * .pi / response
            if t >= 1 { return 1 }
            if damping < 1 {
                let wd = omega * (1 - damping * damping).squareRoot()
                let envelope = exp(-damping * omega * elapsed)
                return 1 - envelope * (cos(wd * elapsed) + (damping * omega / wd) * sin(wd * elapsed))
            }
            return 1 - exp(-omega * elapsed) * (1 + omega * elapsed)
        }
    }

    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        // Solve bezier_x(s) = x with Newton iterations, then evaluate bezier_y(s).
        func bx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s }
        func by(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s }
        func dbx(_ s: Double) -> Double { 3 * (1 - s) * (1 - s) * x1 + 6 * (1 - s) * s * (x2 - x1) + 3 * s * s * (1 - x2) }
        var s = x
        for _ in 0..<8 {
            let error = bx(s) - x
            if abs(error) < 1e-6 { break }
            let derivative = dbx(s)
            if abs(derivative) < 1e-6 { break }
            s -= error / derivative
        }
        return by(min(max(s, 0), 1))
    }
}

public enum AnimationCompletionCriteria: Hashable, Sendable { case logicallyComplete, removed }

/// The context of a state change. `withAnimation` / `Binding.animation` / `.transaction` set it;
/// the renderer and animators read the resolved transaction of each change.
public struct Transaction: @unchecked Sendable {
    public var animation: Animation?
    public var disablesAnimations = false
    public var isContinuous = false
    var completions: [@MainActor () -> Void] = []
    /// Custom values (`TransactionKey`, `@Entry` in `extension Transaction`).
    var values: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<Key: TransactionKey>(key: Key.Type) -> Key.Value {
        get { values[ObjectIdentifier(key)] as? Key.Value ?? Key.defaultValue }
        set { values[ObjectIdentifier(key)] = newValue }
    }
    public init(animation: Animation?) { self.animation = animation }

    var isEmpty: Bool { animation == nil && !disablesAnimations && completions.isEmpty }

    public mutating func addAnimationCompletion(criteria: AnimationCompletionCriteria = .logicallyComplete, _ completion: @escaping @MainActor () -> Void) {
        completions.append(completion)
    }

    /// The transaction of the change currently being applied.
    @MainActor static var current = Transaction()

    /// Merges another pending change into this one (the latest animation wins).
    mutating func merge(_ other: Transaction) {
        if other.animation != nil { animation = other.animation }
        if other.disablesAnimations { disablesAnimations = true }
        completions.append(contentsOf: other.completions)
    }
}

@MainActor
public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    let saved = Transaction.current
    Transaction.current = transaction
    defer { Transaction.current = saved }
    return try body()
}

@MainActor
public func withTransaction<R, V>(_ keyPath: WritableKeyPath<Transaction, V>, _ value: V, _ body: () throws -> R) rethrows -> R {
    var transaction = Transaction.current
    transaction[keyPath: keyPath] = value
    return try withTransaction(transaction, body)
}

@MainActor
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withTransaction(Transaction(animation: animation), body)
}

@MainActor
public func withAnimation<Result>(_ animation: Animation? = .default, completionCriteria: AnimationCompletionCriteria = .logicallyComplete, _ body: () throws -> Result, completion: @escaping @MainActor () -> Void) rethrows -> Result {
    var transaction = Transaction(animation: animation)
    transaction.addAnimationCompletion(criteria: completionCriteria, completion)
    return try withTransaction(transaction, body)
}
