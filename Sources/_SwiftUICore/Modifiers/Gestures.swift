import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Gestures are recognized in the core from raw pointer events delivered by the backend
// (`RenderActions.pointer`), so every platform behaves the same.

@MainActor
public class _GestureRecognizer {
    enum State { case possible, active, ended, failed }
    var state = State.possible
    /// Called when the gesture ends or fails (resets `@GestureState`).
    var resetHandlers: [@MainActor () -> Void] = []

    func handle(_ event: PointerEvent) {}

    func finish(_ final: State) {
        state = final
        for reset in resetHandlers { reset() }
    }
}

@MainActor
public class _TypedRecognizer<Value>: _GestureRecognizer {
    var changed: [@MainActor (Value) -> Void] = []
    var ended: [@MainActor (Value) -> Void] = []

    func emitChanged(_ value: Value) { for handler in changed { handler(value) } }
    func emitEnded(_ value: Value) {
        for handler in ended { handler(value) }
        finish(.ended)
    }
}

@MainActor @preconcurrency
public protocol Gesture<Value> {
    associatedtype Value
    func _makeRecognizer() -> _TypedRecognizer<Value>
}

// MARK: - Primitive gestures

public struct TapGesture: Gesture {
    public typealias Value = Void
    public var count: Int
    public init(count: Int = 1) { self.count = count }

    public func _makeRecognizer() -> _TypedRecognizer<Void> { TapRecognizer(count: count) }

    final class TapRecognizer: _TypedRecognizer<Void> {
        let count: Int
        var taps = 0
        var start: PointerEvent?
        var lastTapTime: Double = -1
        init(count: Int) { self.count = count }

        override func handle(_ event: PointerEvent) {
            switch event.phase {
            case .began:
                if event.timestamp - lastTapTime > 0.4 { taps = 0 }
                start = event
            case .moved:
                if let start, distance(start.location, event.location) > 10 { finish(.failed) }
            case .ended:
                guard let start, distance(start.location, event.location) <= 10 else { return finish(.failed) }
                taps += 1
                lastTapTime = event.timestamp
                if taps >= count {
                    taps = 0
                    emitEnded(())
                }
            case .cancelled:
                finish(.failed)
            }
        }
    }
}

public struct SpatialTapGesture: Gesture {
    public struct Value: Equatable, Sendable { public var location: CGPoint }
    public var count: Int
    public var coordinateSpace: CoordinateSpace
    public init(count: Int = 1, coordinateSpace: CoordinateSpace = .local) {
        self.count = count
        self.coordinateSpace = coordinateSpace
    }

    public func _makeRecognizer() -> _TypedRecognizer<Value> {
        let recognizer = SpatialRecognizer()
        return recognizer
    }

    final class SpatialRecognizer: _TypedRecognizer<Value> {
        var start: CGPoint?
        override func handle(_ event: PointerEvent) {
            switch event.phase {
            case .began: start = event.location
            case .ended:
                if let start, distance(start, event.location) <= 10 { emitEnded(Value(location: event.location)) } else { finish(.failed) }
            case .cancelled: finish(.failed)
            case .moved: break
            }
        }
    }
}

public struct LongPressGesture: Gesture {
    public typealias Value = Bool
    public var minimumDuration: Double
    public var maximumDistance: CGFloat

    public init(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10) {
        self.minimumDuration = minimumDuration
        self.maximumDistance = maximumDistance
    }

    public func _makeRecognizer() -> _TypedRecognizer<Bool> { LongPressRecognizer(duration: minimumDuration, maximumDistance: maximumDistance) }

    final class LongPressRecognizer: _TypedRecognizer<Bool> {
        let duration: Double
        let maximumDistance: CGFloat
        var start: PointerEvent?
        var generation = 0

        init(duration: Double, maximumDistance: CGFloat) {
            self.duration = duration
            self.maximumDistance = maximumDistance
        }

        override func handle(_ event: PointerEvent) {
            switch event.phase {
            case .began:
                start = event
                state = .active
                emitChanged(true)
                generation += 1
                let current = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == current, self.state == .active else { return }
                        self.emitEnded(true)
                    }
                }
            case .moved:
                if let start, distance(start.location, event.location) > maximumDistance {
                    generation += 1
                    finish(.failed)
                }
            case .ended:
                if let start, state == .active, event.timestamp - start.timestamp >= duration {
                    emitEnded(true)
                } else if state == .active {
                    generation += 1
                    finish(.failed)
                }
            case .cancelled:
                generation += 1
                finish(.failed)
            }
        }
    }
}

public struct DragGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var location: CGPoint
        public var startLocation: CGPoint
        public var velocity: CGSize
        public var translation: CGSize { CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y) }
        public var predictedEndLocation: CGPoint {
            CGPoint(x: location.x + velocity.width * 0.25, y: location.y + velocity.height * 0.25)
        }
        public var predictedEndTranslation: CGSize {
            CGSize(width: predictedEndLocation.x - startLocation.x, height: predictedEndLocation.y - startLocation.y)
        }
    }

    public var minimumDistance: CGFloat
    public var coordinateSpace: CoordinateSpace

    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
        self.coordinateSpace = coordinateSpace
    }

    public func _makeRecognizer() -> _TypedRecognizer<Value> { DragRecognizer(minimumDistance: minimumDistance) }

    final class DragRecognizer: _TypedRecognizer<Value> {
        let minimumDistance: CGFloat
        var start: PointerEvent?
        var last: PointerEvent?
        var velocity = CGSize.zero

        init(minimumDistance: CGFloat) { self.minimumDistance = minimumDistance }

        private func value(_ event: PointerEvent) -> Value {
            Value(time: Date(), location: event.location, startLocation: start?.location ?? event.location, velocity: velocity)
        }

        override func handle(_ event: PointerEvent) {
            switch event.phase {
            case .began:
                start = event
                last = event
                velocity = .zero
                if minimumDistance <= 0 {
                    state = .active
                    emitChanged(value(event))
                }
            case .moved:
                guard let start else { return }
                if let last, event.timestamp > last.timestamp {
                    let dt = event.timestamp - last.timestamp
                    velocity = CGSize(width: (event.location.x - last.location.x) / dt, height: (event.location.y - last.location.y) / dt)
                }
                last = event
                if state != .active, distance(start.location, event.location) >= minimumDistance { state = .active }
                if state == .active { emitChanged(value(event)) }
            case .ended:
                if state == .active { emitEnded(value(event)) } else { finish(.failed) }
            case .cancelled:
                finish(.failed)
            }
        }
    }
}

/// Moves the window when dragged (a custom title bar's empty space). The backend runs the
/// platform's own window drag from the mouse-down, so the gesture itself reports nothing.
public struct WindowDragGesture: Gesture {
    public typealias Value = Void
    public init() {}

    public func _makeRecognizer() -> _TypedRecognizer<Void> { WindowDragRecognizer() }

    final class WindowDragRecognizer: _TypedRecognizer<Void> {
        override func handle(_ event: PointerEvent) {
            switch event.phase {
            case .began:
                state = .active
                AppRuntime.performWindowDrag?()
            case .moved: break
            case .ended: emitEnded(())
            case .cancelled: finish(.failed)
            }
        }
    }
}

/// Pinch / rotation need multi-touch input; on pointer-only platforms they never fire.
public struct MagnifyGesture: Gesture {
    public struct Value: Equatable, Sendable { public var magnification: CGFloat; public var startLocation: CGPoint }
    public init(minimumScaleDelta: CGFloat = 0.01) {}
    public func _makeRecognizer() -> _TypedRecognizer<Value> { _TypedRecognizer() }
}

public struct RotateGesture: Gesture {
    public struct Value: Equatable, Sendable { public var rotation: Angle; public var startLocation: CGPoint }
    public init(minimumAngleDelta: Angle = .degrees(1)) {}
    public func _makeRecognizer() -> _TypedRecognizer<Value> { _TypedRecognizer() }
}

@MainActor
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
}

// MARK: - Combinators

public struct _ChangedGesture<Base: Gesture>: Gesture {
    let base: Base
    let action: @MainActor (Base.Value) -> Void
    public func _makeRecognizer() -> _TypedRecognizer<Base.Value> {
        let recognizer = base._makeRecognizer()
        recognizer.changed.append(action)
        return recognizer
    }
}

public struct _EndedGesture<Base: Gesture>: Gesture {
    let base: Base
    let action: @MainActor (Base.Value) -> Void
    public func _makeRecognizer() -> _TypedRecognizer<Base.Value> {
        let recognizer = base._makeRecognizer()
        recognizer.ended.append(action)
        return recognizer
    }
}

public struct _MapGesture<Base: Gesture, Value>: Gesture {
    let base: Base
    let transform: @MainActor (Base.Value) -> Value
    public func _makeRecognizer() -> _TypedRecognizer<Value> {
        let inner = base._makeRecognizer()
        let outer = _ForwardingRecognizer<Value>(inner: inner)
        inner.changed.append { [unowned outer] in outer.emitChanged(transform($0)) }
        inner.ended.append { [unowned outer] in outer.emitEnded(transform($0)) }
        return outer
    }
}

/// Delivers events to `inner` and mirrors its state.
@MainActor
final class _ForwardingRecognizer<Value>: _TypedRecognizer<Value> {
    let inner: _GestureRecognizer
    init(inner: _GestureRecognizer) { self.inner = inner }
    override func handle(_ event: PointerEvent) {
        inner.handle(event)
        if inner.state == .failed, state != .failed { finish(.failed) }
    }
}

public struct _UpdatingGesture<Base: Gesture, State>: Gesture {
    let base: Base
    let state: GestureState<State>
    let body: @MainActor (Base.Value, inout State, inout Transaction) -> Void

    public func _makeRecognizer() -> _TypedRecognizer<Base.Value> {
        let recognizer = base._makeRecognizer()
        let gestureState = state
        let update = body
        recognizer.changed.append { value in
            var current = gestureState.wrappedValue
            var transaction = Transaction()
            update(value, &current, &transaction)
            withTransaction(transaction) { gestureState.set(current) }
        }
        recognizer.resetHandlers.append { gestureState.reset() }
        return recognizer
    }
}

public struct SimultaneousGesture<First: Gesture, Second: Gesture>: Gesture {
    public struct Value { public var first: First.Value?; public var second: Second.Value? }
    let first: First
    let second: Second

    public func _makeRecognizer() -> _TypedRecognizer<Value> {
        let a = first._makeRecognizer()
        let b = second._makeRecognizer()
        let combined = _MultiRecognizer<Value>(children: [a, b])
        a.changed.append { [unowned combined] in combined.emitChanged(Value(first: $0, second: nil)) }
        b.changed.append { [unowned combined] in combined.emitChanged(Value(first: nil, second: $0)) }
        a.ended.append { [unowned combined] in combined.emitEnded(Value(first: $0, second: nil)) }
        b.ended.append { [unowned combined] in combined.emitEnded(Value(first: nil, second: $0)) }
        return combined
    }
}

public struct SequenceGesture<First: Gesture, Second: Gesture>: Gesture {
    public enum Value { case first(First.Value), second(First.Value, Second.Value?) }
    let first: First
    let second: Second

    public func _makeRecognizer() -> _TypedRecognizer<Value> {
        let a = first._makeRecognizer()
        let b = second._makeRecognizer()
        let combined = _SequenceRecognizer<Value>(first: a, second: b)
        var firstValue: First.Value?
        a.changed.append { [unowned combined] in combined.emitChanged(.first($0)) }
        a.ended.append { value in firstValue = value }
        b.changed.append { [unowned combined] value in if let firstValue { combined.emitChanged(.second(firstValue, value)) } }
        b.ended.append { [unowned combined] value in if let firstValue { combined.emitEnded(.second(firstValue, value)) } }
        return combined
    }
}

public struct ExclusiveGesture<First: Gesture, Second: Gesture>: Gesture {
    public enum Value { case first(First.Value), second(Second.Value) }
    let first: First
    let second: Second

    public func _makeRecognizer() -> _TypedRecognizer<Value> {
        let a = first._makeRecognizer()
        let b = second._makeRecognizer()
        let combined = _MultiRecognizer<Value>(children: [a, b], exclusive: true)
        a.changed.append { [unowned combined] in combined.emitChanged(.first($0)) }
        a.ended.append { [unowned combined] in combined.emitEnded(.first($0)) }
        b.changed.append { [unowned combined] in if a.state != .active { combined.emitChanged(.second($0)) } }
        b.ended.append { [unowned combined] in if a.state != .ended { combined.emitEnded(.second($0)) } }
        return combined
    }
}

@MainActor
final class _MultiRecognizer<Value>: _TypedRecognizer<Value> {
    let children: [_GestureRecognizer]
    let exclusive: Bool
    init(children: [_GestureRecognizer], exclusive: Bool = false) {
        self.children = children
        self.exclusive = exclusive
    }
    override func handle(_ event: PointerEvent) {
        for child in children where child.state != .failed && child.state != .ended {
            child.handle(event)
            if exclusive, child.state == .ended { break }
        }
        if children.allSatisfy({ $0.state == .failed }) { finish(.failed) }
    }
}

@MainActor
final class _SequenceRecognizer<Value>: _TypedRecognizer<Value> {
    let first: _GestureRecognizer
    let second: _GestureRecognizer
    init(first: _GestureRecognizer, second: _GestureRecognizer) {
        self.first = first
        self.second = second
    }
    override func handle(_ event: PointerEvent) {
        if first.state != .ended {
            first.handle(event)
            if first.state == .failed { finish(.failed) }
            if first.state == .ended, event.phase != .ended {
                second.handle(PointerEvent(phase: .began, location: event.location, timestamp: event.timestamp))
            }
        } else {
            second.handle(event)
            if second.state == .failed { finish(.failed) }
        }
    }
}

extension Gesture {
    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> _ChangedGesture<Self> { _ChangedGesture(base: self, action: action) }
    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> _EndedGesture<Self> { _EndedGesture(base: self, action: action) }
    public func map<T>(_ body: @escaping @MainActor (Value) -> T) -> _MapGesture<Self, T> { _MapGesture(base: self, transform: body) }
    public func updating<State>(_ state: GestureState<State>, body: @escaping @MainActor (Value, inout State, inout Transaction) -> Void) -> _UpdatingGesture<Self, State> {
        _UpdatingGesture(base: self, state: state, body: body)
    }
    public func simultaneously<Other: Gesture>(with other: Other) -> SimultaneousGesture<Self, Other> { SimultaneousGesture(first: self, second: other) }
    public func sequenced<Other: Gesture>(before other: Other) -> SequenceGesture<Self, Other> { SequenceGesture(first: self, second: other) }
    public func exclusively<Other: Gesture>(before other: Other) -> ExclusiveGesture<Self, Other> { ExclusiveGesture(first: self, second: other) }
}

// MARK: - @GestureState

@propertyWrapper
public struct GestureState<Value>: DynamicProperty {
    let initial: Value
    var location: StoredLocation<Value>?

    public init(wrappedValue: Value) { initial = wrappedValue }
    public init(initialValue: Value) { initial = initialValue }
    public init(wrappedValue: Value, resetTransaction: Transaction) { initial = wrappedValue }

    public var wrappedValue: Value { location?.get() ?? initial }
    public var projectedValue: GestureState<Value> { self }

    func set(_ value: Value) { location?.set(value, transaction: Transaction.current) }
    func reset() { location?.set(initial, transaction: Transaction.current) }
}

extension GestureState: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let existing = slot as? StoredLocation<Value> {
            location = existing
            return
        }
        let created = StoredLocation(attribute: Attribute(context.subgraph, value: initial))
        slot = created
        location = created
    }
}

extension GestureState: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: GestureState, _ rhs: GestureState) -> Bool { true }
}

// MARK: - Attaching gestures

public enum GesturePriority { case normal, simultaneous, high }

public struct GestureMask: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let none = GestureMask([])
    public static let gesture = GestureMask(rawValue: 1)
    public static let subviews = GestureMask(rawValue: 2)
    public static let all: GestureMask = [.gesture, .subviews]
}

@MainActor
final class GestureSession {
    var recognizer: _GestureRecognizer?
}

public struct _GestureModifier<G: Gesture>: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let gesture: G
    var isEnabled = true
    static var pathComponent: String { "gesture" }
    func effect(size: CGSize) -> DisplayEffect { isEnabled ? .tapTarget : .group }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        let session = GestureSession()
        var actions = RenderActions()
        actions.pointer = { [weak modifier] event in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies {
                guard modifier.value.isEnabled else { session.recognizer = nil; return }
                if event.phase == .began || session.recognizer == nil || session.recognizer?.state == .ended || session.recognizer?.state == .failed {
                    if event.phase != .began { return }
                    session.recognizer = modifier.value.gesture._makeRecognizer()
                }
                session.recognizer?.handle(event)
            }
        }
        return actions
    }
}

extension View {
    public func gesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: mask.contains(.gesture)))
    }

    public func gesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func gesture<G: Gesture>(_ gesture: G, name: String, isEnabled: Bool = true) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func simultaneousGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: mask.contains(.gesture)))
    }

    public func simultaneousGesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func simultaneousGesture<G: Gesture>(_ gesture: G, name: String, isEnabled: Bool = true) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func highPriorityGesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func highPriorityGesture<G: Gesture>(_ gesture: G, name: String, isEnabled: Bool = true) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: isEnabled))
    }

    public func highPriorityGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        modifier(_GestureModifier(gesture: gesture, isEnabled: mask.contains(.gesture)))
    }

    public func onLongPressGesture(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10, perform action: @escaping @MainActor () -> Void, onPressingChanged: (@MainActor (Bool) -> Void)? = nil) -> some View {
        gesture(LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance)
            .onChanged { pressing in onPressingChanged?(pressing) }
            .onEnded { _ in
                onPressingChanged?(false)
                action()
            })
    }

    public func onTapGesture(count: Int = 1, coordinateSpace: CoordinateSpace = .local, perform action: @escaping @MainActor (CGPoint) -> Void) -> some View {
        gesture(SpatialTapGesture(count: count, coordinateSpace: coordinateSpace).onEnded { action($0.location) })
    }

    public func onHover(perform action: @escaping @MainActor (Bool) -> Void) -> some View {
        modifier(_HoverModifier(action: action))
    }

    @_disfavoredOverload public func onContinuousHover(coordinateSpace: CoordinateSpace = .local, perform action: @escaping @MainActor (HoverPhase) -> Void) -> some View {
        modifier(_ContinuousHoverModifier(coordinateSpace: coordinateSpace, action: action))
    }

    public func onContinuousHover(coordinateSpace: some CoordinateSpaceProtocol = .local, perform action: @escaping @MainActor (HoverPhase) -> Void) -> some View {
        modifier(_ContinuousHoverModifier(coordinateSpace: coordinateSpace.coordinateSpace, action: action))
    }
}

public enum HoverPhase: Equatable, Sendable {
    case active(CGPoint)
    case ended
}

struct _HoverModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let action: @MainActor (Bool) -> Void
    static var pathComponent: String { "onHover" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }
    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.hover = { [weak modifier] hovering in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.action(hovering) }
        }
        return actions
    }
}

/// Reports the pointer location in the requested coordinate space while it hovers the view.
struct _ContinuousHoverModifier: ViewModifier {
    let coordinateSpace: CoordinateSpace
    let action: @MainActor (HoverPhase) -> Void
    typealias Body = Never

    static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "onContinuousHover")
        let geometry = inputs.geometry
        let spaces = inputs.coordinateSpaces
        let source = modifier.attribute
        let content = Attribute<RenderContent>(inputs.subgraph) { .effect(.opacity(1)) }
        var actions = RenderActions()
        actions.hover = { _ in }
        actions.hoverLocation = { [weak source] point in
            guard let source else { return }
            AnyAttribute.withoutDependencies {
                let current = source.value
                guard let point else { return current.action(.ended) }
                let origin = GeometryProxy(geometry: geometry.value, spaces: spaces).frame(in: current.coordinateSpace).origin
                current.action(.active(CGPoint(x: point.x + origin.x, y: point.y + origin.y)))
            }
        }
        let render = inputs.makePlatformNode(content: content, actions: actions)
        var childInputs = inputs
        childInputs.render = render
        return body(childInputs)
    }
}

// MARK: - matchedGeometryEffect

@propertyWrapper
public struct Namespace: DynamicProperty {
    public struct ID: Hashable, Sendable { let value: Int }
    var id: ID?

    public init() {}

    public var wrappedValue: ID { id ?? ID(value: MainActor.assumeIsolated { NamespaceCounter.next() }) }
}

@MainActor
enum NamespaceCounter {
    static var value = 0
    static func next() -> Int {
        value += 1
        return value
    }
}

@MainActor
final class NamespaceBox {
    let id = Namespace.ID(value: NamespaceCounter.next())
}

extension Namespace: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        let box = (slot as? NamespaceBox) ?? NamespaceBox()
        slot = box
        id = box.id
    }
}

extension Namespace: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: Namespace, _ rhs: Namespace) -> Bool { true }
}

public struct MatchedGeometryProperties: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let position = MatchedGeometryProperties(rawValue: 1)
    public static let size = MatchedGeometryProperties(rawValue: 2)
    public static let frame: MatchedGeometryProperties = [.position, .size]
}

public struct _MatchedGeometryModifier: ViewModifier {
    let key: AnyHashable
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let renderer = inputs.host.renderer
        let group = renderer.makeGroup(path: inputs.path)
        group.matchKey = AnyAttribute.withoutDependencies { modifier.attribute.value.key }
        renderer.append(group, to: inputs.render.parent)
        inputs.subgraph.onDestroy { renderer.remove(group) }
        var childInputs = inputs
        childInputs.render = _RenderInputs(parent: group, origin: inputs.render.origin)
        return body(childInputs)
    }
}

struct MatchKey: Hashable {
    let namespace: Namespace.ID
    let id: AnyHashable
}

extension View {
    public func matchedGeometryEffect<ID: Hashable>(id: ID, in namespace: Namespace.ID, properties: MatchedGeometryProperties = .frame, anchor: UnitPoint = .center, isSource: Bool = true) -> some View {
        modifier(_MatchedGeometryModifier(key: AnyHashable(MatchKey(namespace: namespace, id: AnyHashable(id)))))
    }
}
