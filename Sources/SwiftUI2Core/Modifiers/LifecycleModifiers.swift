import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// onAppear / onDisappear: fire after the update in which the view's identity was inserted /
/// removed (not on every update), like SwiftUI.
public struct _AppearanceActionModifier: ViewModifier {
    var appear: (@MainActor () -> Void)?
    var disappear: (@MainActor () -> Void)?
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let attribute = modifier.attribute
        host.enqueueAfterUpdate { [weak attribute] in
            attribute?.value.appear?()
        }
        inputs.subgraph.onDestroy { [weak host] in
            guard let disappear = attribute.peekValue?.disappear else { return }
            host?.enqueueAfterUpdate { disappear() }
        }
        return body(inputs)
    }
}

/// onChange(of:): an eager attribute that compares the value after each update and runs the action
/// after the update completes.
public struct _ValueActionModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: @MainActor (Value, Value) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let source = modifier.attribute
        let previous = LastValue<Value>()
        let observer = Attribute<Value>(inputs.subgraph, isEqual: { $0 == $1 }) { source.value.value }
        observer.order = inputs.depth
        observer.onChange = { [weak source] newValue in
            defer { previous.value = newValue }
            guard let old = previous.value else {
                if let current = source?.peekValue, current.initial {
                    host.enqueueAfterUpdate { current.action(newValue, newValue) }
                }
                return
            }
            guard let action = source?.peekValue?.action else { return }
            host.enqueueAfterUpdate { action(old, newValue) }
        }
        observer.isEager = true
        return body(inputs)
    }
}

/// `.task`: starts on appear, cancelled on disappear (or when `id` changes).
public struct _TaskModifier<ID: Equatable>: ViewModifier {
    let id: ID
    let priority: TaskPriority
    let action: @MainActor @Sendable () async -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let source = modifier.attribute
        let running = LastValue<Task<Void, Never>>()
        let id = Attribute<ID>(inputs.subgraph, isEqual: { $0 == $1 }) { source.value.id }
        id.order = inputs.depth
        id.onChange = { [weak source] _ in
            host.enqueueAfterUpdate {
                running.value?.cancel()
                guard let task = source?.peekValue else { return }
                running.value = Task(priority: task.priority) { @MainActor in await task.action() }
            }
        }
        id.isEager = true
        inputs.subgraph.onDestroy { running.value?.cancel() }
        return body(inputs)
    }
}

extension View {
    public func onAppear(perform action: (@MainActor () -> Void)? = nil) -> some View {
        modifier(_AppearanceActionModifier(appear: action, disappear: nil))
    }

    public func onDisappear(perform action: (@MainActor () -> Void)? = nil) -> some View {
        modifier(_AppearanceActionModifier(appear: nil, disappear: action))
    }

    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping @MainActor (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        modifier(_ValueActionModifier(value: value, initial: initial, action: action))
    }

    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping @MainActor () -> Void) -> some View {
        modifier(_ValueActionModifier(value: value, initial: initial) { _, _ in action() })
    }

    public func task(priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(_TaskModifier(id: 0, priority: priority, action: action))
    }

    public func task<T: Equatable>(id value: T, priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(_TaskModifier(id: value, priority: priority, action: action))
    }
}
