import Foundation
import Observation

// MARK: - Focused values

public protocol FocusedValueKey {
    associatedtype Value
}

/// Values published by the focused view (`focusedValue`) or the active scene
/// (`focusedSceneValue`), read with `@FocusedValue` — typically by menu commands.
public struct FocusedValues: @unchecked Sendable {
    var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public subscript<Key: FocusedValueKey>(key: Key.Type) -> Key.Value? {
        get { storage[ObjectIdentifier(key)] as? Key.Value }
        set { storage[ObjectIdentifier(key)] = newValue }
    }

    subscript(object type: Any.Type) -> AnyObject? {
        get { storage[ObjectIdentifier(type)] as AnyObject? }
        set { storage[ObjectIdentifier(type)] = newValue }
    }
}

/// The focused values of the active window. Observable, so views and commands reading them
/// update when focus or the published values change.
@Observable
@MainActor
public final class FocusedValuesCenter {
    public static let shared = FocusedValuesCenter()
    public private(set) var values = FocusedValues()
    @ObservationIgnored weak var activeGraph: ViewGraph?

    func publish(_ values: FocusedValues, from graph: ViewGraph) {
        if activeGraph == nil { activeGraph = graph }
        guard activeGraph === graph else { return }
        self.values = values
    }

    /// Makes `graph` (e.g. the key window's) the source of focused values.
    public func activate(_ graph: ViewGraph) {
        activeGraph = graph
        values = graph.focusedValueRegistry.resolve()
    }
}

/// Per-graph registrations of `focusedValue` / `focusedSceneValue` and the focused view.
@MainActor
final class FocusedValueRegistry {
    struct Entry {
        let path: ViewPath
        let isScene: Bool
        let order: Int
        var apply: (inout FocusedValues) -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextOrder = 0
    /// Path of the platform view with keyboard focus.
    var focusedPath: ViewPath?

    func set(_ owner: AnyObject, path: ViewPath, isScene: Bool, apply: @escaping (inout FocusedValues) -> Void) {
        let key = ObjectIdentifier(owner)
        if var entry = entries[key] {
            entry.apply = apply
            entries[key] = entry
        } else {
            nextOrder += 1
            entries[key] = Entry(path: path, isScene: isScene, order: nextOrder, apply: apply)
        }
    }

    func remove(_ owner: AnyObject) { entries[ObjectIdentifier(owner)] = nil }

    /// Scene values always apply; view values only when their view contains the focus. Deeper
    /// registrations win.
    func resolve() -> FocusedValues {
        var values = FocusedValues()
        let active = entries.values.filter { $0.isScene || contains(focus: $0.path) }
        for entry in active.sorted(by: { (depth($0.path), $0.order) < (depth($1.path), $1.order) }) {
            entry.apply(&values)
        }
        return values
    }

    private func contains(focus ancestor: ViewPath) -> Bool {
        var current = focusedPath
        while let path = current {
            if path === ancestor { return true }
            current = path.parent
        }
        return false
    }

    private func depth(_ path: ViewPath) -> Int {
        var count = 0
        var current: ViewPath? = path
        while let path = current { count += 1; current = path.parent }
        return count
    }
}

extension ViewGraph {
    /// The platform view with keyboard focus changed (backends report its node).
    public func setFocusedNode(_ node: RenderNode?) {
        focusedValueRegistry.focusedPath = node?.path
        publishFocusedValues()
    }

    func publishFocusedValues() {
        FocusedValuesCenter.shared.publish(focusedValueRegistry.resolve(), from: self)
    }
}

/// Registers a focused value while the modified view exists.
public struct _FocusedValueModifier: ViewModifier {
    let isScene: Bool
    let apply: (inout FocusedValues) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let registry = host.focusedValueRegistry
        let owner = _FocusedValueOwner()
        let path = inputs.path
        let registration = Attribute<Int>(inputs.subgraph) {
            let current = modifier.attribute.value
            registry.set(owner, path: path, isScene: current.isScene, apply: current.apply)
            owner.revision += 1
            return owner.revision
        }
        registration.onChange = { _ in host.enqueueAfterUpdate { host.publishFocusedValues() } }
        registration.isEager = true
        inputs.subgraph.onDestroy { [weak host] in
            registry.remove(owner)
            host?.enqueueAfterUpdate { host?.publishFocusedValues() }
        }
        return body(inputs)
    }
}

final class _FocusedValueOwner { var revision = 0 }

extension View {
    public func focusedValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value?) -> some View {
        modifier(_FocusedValueModifier(isScene: false) { $0[keyPath: keyPath] = value })
    }

    public func focusedValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value) -> some View {
        modifier(_FocusedValueModifier(isScene: false) { $0[keyPath: keyPath] = value })
    }

    public func focusedSceneValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value?) -> some View {
        modifier(_FocusedValueModifier(isScene: true) { $0[keyPath: keyPath] = value })
    }

    public func focusedSceneValue<Value>(_ keyPath: WritableKeyPath<FocusedValues, Value?>, _ value: Value) -> some View {
        modifier(_FocusedValueModifier(isScene: true) { $0[keyPath: keyPath] = value })
    }

    /// Publishes an `@Observable` object (read with `@FocusedValue(Type.self)`).
    public func focusedValue<T: AnyObject & Observable>(_ object: T?) -> some View {
        modifier(_FocusedValueModifier(isScene: false) { $0[object: T.self] = object })
    }

    public func focusedSceneValue<T: AnyObject & Observable>(_ object: T?) -> some View {
        modifier(_FocusedValueModifier(isScene: true) { $0[object: T.self] = object })
    }

    public func focusedObject<T: ObservableObject>(_ object: T?) -> some View {
        modifier(_FocusedValueModifier(isScene: false) { $0[object: T.self] = object })
    }

    public func focusedSceneObject<T: ObservableObject>(_ object: T?) -> some View {
        modifier(_FocusedValueModifier(isScene: true) { $0[object: T.self] = object })
    }
}

// MARK: - Property wrappers

/// The focused value for a key path of `FocusedValues` (nil when nothing publishes it).
@propertyWrapper
public struct FocusedValue<Value>: DynamicProperty {
    let read: @MainActor (FocusedValues) -> Value?

    public init(_ keyPath: KeyPath<FocusedValues, Value?>) {
        read = { $0[keyPath: keyPath] }
    }

    public init(_ objectType: Value.Type) where Value: AnyObject & Observable {
        read = { $0[object: objectType] as? Value }
    }

    @MainActor public var wrappedValue: Value? { read(FocusedValuesCenter.shared.values) }
}

/// A focused binding (`focusedValue(\.key, $state)`), exposed as an optional value.
@propertyWrapper
public struct FocusedBinding<Value>: DynamicProperty {
    let keyPath: KeyPath<FocusedValues, Binding<Value>?>

    public init(_ keyPath: KeyPath<FocusedValues, Binding<Value>?>) { self.keyPath = keyPath }

    @MainActor public var wrappedValue: Value? {
        get { FocusedValuesCenter.shared.values[keyPath: keyPath]?.wrappedValue }
        nonmutating set {
            guard let newValue, let binding = FocusedValuesCenter.shared.values[keyPath: keyPath] else { return }
            binding.wrappedValue = newValue
        }
    }

    @MainActor public var projectedValue: Binding<Value?> {
        let keyPath = self.keyPath
        return Binding(get: { FocusedValuesCenter.shared.values[keyPath: keyPath]?.wrappedValue }, set: { newValue in
            guard let newValue, let binding = FocusedValuesCenter.shared.values[keyPath: keyPath] else { return }
            binding.wrappedValue = newValue
        })
    }
}

/// The focused `ObservableObject` of a type (`focusedObject`).
@propertyWrapper
public struct FocusedObject<ObjectType: ObservableObject>: DynamicProperty {
    public init() {}

    @MainActor public var wrappedValue: ObjectType? { FocusedValuesCenter.shared.values[object: ObjectType.self] as? ObjectType }

    @MainActor public var projectedValue: Wrapper? { wrappedValue.map(Wrapper.init) }

    @dynamicMemberLookup
    public struct Wrapper {
        let object: ObjectType
        @MainActor public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, T>) -> Binding<T> {
            let object = self.object
            return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
        }
    }
}
