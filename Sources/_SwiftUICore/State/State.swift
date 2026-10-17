import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Locations

/// Storage behind a `Binding`.
@MainActor
class AnyLocation<Value> {
    func get() -> Value { fatalError("abstract") }
    func set(_ value: Value, transaction: Transaction) { fatalError("abstract") }
    /// Two bindings with equal locations are interchangeable (used for view comparison).
    func isEqual(to other: AnyLocation<Value>) -> Bool { self === other }
}

/// Location backed by a graph source attribute (`@State`). Reads inside a rule register a
/// dependency on exactly this piece of state.
@MainActor
final class StoredLocation<Value>: AnyLocation<Value> {
    let attribute: Attribute<Value>

    init(attribute: Attribute<Value>) { self.attribute = attribute }

    override func get() -> Value { attribute.value }

    override func set(_ value: Value, transaction: Transaction) {
        if transaction.isEmpty {
            attribute.setValue(value)
        } else {
            withTransaction(transaction) { attribute.setValue(value) }
        }
    }
}

@MainActor
final class FunctionLocation<Value>: AnyLocation<Value> {
    let getter: () -> Value
    let setter: (Value, Transaction) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value, Transaction) -> Void) {
        self.getter = get
        self.setter = set
    }

    override func get() -> Value { getter() }
    override func set(_ value: Value, transaction: Transaction) { setter(value, transaction) }
}

@MainActor
final class ConstantLocation<Value>: AnyLocation<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
    override func get() -> Value { value }
    override func set(_ value: Value, transaction: Transaction) {}
    override func isEqual(to other: AnyLocation<Value>) -> Bool {
        guard let other = other as? ConstantLocation<Value> else { return false }
        return GraphComparison.isIdentical(value, other.value)
    }
}

@MainActor
final class ProjectedLocation<Base, Value>: AnyLocation<Value> {
    let base: AnyLocation<Base>
    let keyPath: WritableKeyPath<Base, Value>

    init(base: AnyLocation<Base>, keyPath: WritableKeyPath<Base, Value>) {
        self.base = base
        self.keyPath = keyPath
    }

    override func get() -> Value { base.get()[keyPath: keyPath] }

    override func set(_ value: Value, transaction: Transaction) {
        var root = base.get()
        root[keyPath: keyPath] = value
        base.set(root, transaction: transaction)
    }

    override func isEqual(to other: AnyLocation<Value>) -> Bool {
        guard let other = other as? ProjectedLocation<Base, Value> else { return false }
        return keyPath == other.keyPath && base.isEqual(to: other.base)
    }
}

/// Location for `@Bindable` / `ObservedObject.Wrapper` projections into a reference type.
@MainActor
final class ObjectLocation<Root: AnyObject, Value>: AnyLocation<Value> {
    let root: Root
    let keyPath: ReferenceWritableKeyPath<Root, Value>

    init(root: Root, keyPath: ReferenceWritableKeyPath<Root, Value>) {
        self.root = root
        self.keyPath = keyPath
    }

    override func get() -> Value { root[keyPath: keyPath] }
    override func set(_ value: Value, transaction: Transaction) {
        withTransaction(transaction) { root[keyPath: keyPath] = value }
    }

    override func isEqual(to other: AnyLocation<Value>) -> Bool {
        guard let other = other as? ObjectLocation<Root, Value> else { return false }
        return root === other.root && keyPath == other.keyPath
    }
}

// MARK: - State

/// Mirrors `SwiftUI.State`. Storage lives in the graph (a source attribute owned by the view's
/// identity); the struct itself is only a handle, so it never makes a view value look changed.
@propertyWrapper
public struct State<Value>: DynamicProperty {
    var _value: Value
    var _location: StoredLocation<Value>?

    public init(wrappedValue value: Value) {
        _value = value
    }

    public init(initialValue value: Value) {
        _value = value
    }

    public var wrappedValue: Value {
        get {
            if let _location { return _location.get() }
            return _value
        }
        nonmutating set {
            guard let _location else {
                runtimeWarning("Accessing State's value outside of being installed on a View. This will result in a constant Binding of the initial value and will not update.")
                return
            }
            _location.set(newValue, transaction: Transaction.current)
        }
    }

    public var projectedValue: Binding<Value> {
        guard let _location else { return .constant(_value) }
        return Binding(location: _location)
    }
}

extension State where Value: ExpressibleByNilLiteral {
    public init() { self.init(wrappedValue: nil) }
}

extension State: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let location = slot as? StoredLocation<Value> {
            _location = location
            return
        }
        let attribute = Attribute<Value>(context.subgraph, value: _value)
        attribute.label = "state \(context.path)"
        let location = StoredLocation(attribute: attribute)
        slot = location
        _location = location
    }
}

extension State: _GraphComparable {
    // State is graph-managed; the initial value passed by a re-evaluated parent is ignored.
    public nonisolated static func _isIdentical(_ lhs: State<Value>, _ rhs: State<Value>) -> Bool { true }
}

// MARK: - Binding

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value>: DynamicProperty {
    let location: AnyLocation<Value>
    public var transaction: Transaction = Transaction()

    init(location: AnyLocation<Value>, transaction: Transaction = Transaction()) {
        self.location = location
        self.transaction = transaction
    }

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.init(location: FunctionLocation(get: get, set: { value, _ in set(value) }))
    }

    public init(get: @escaping () -> Value, set: @escaping (Value, Transaction) -> Void) {
        self.init(location: FunctionLocation(get: get, set: set))
    }

    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(location: ConstantLocation(value))
    }

    public var wrappedValue: Value {
        get { location.get() }
        nonmutating set { location.set(newValue, transaction: transaction.isEmpty ? Transaction.current : transaction) }
    }

    public var projectedValue: Binding<Value> { self }

    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        Binding<Subject>(location: ProjectedLocation(base: location, keyPath: keyPath), transaction: transaction)
    }

    public func transaction(_ transaction: Transaction) -> Binding<Value> {
        var copy = self
        copy.transaction = transaction
        return copy
    }

    public func animation(_ animation: Animation? = .default) -> Binding<Value> {
        var copy = self
        copy.transaction.animation = animation
        return copy
    }
}

extension Binding {
    /// Unwraps a binding to an optional (nil when the base is nil).
    public init?(_ base: Binding<Value?>) {
        guard let initial = base.wrappedValue else { return nil }
        let box = LastValueBox(initial)
        self.init(get: {
            if let value = base.wrappedValue { box.value = value }
            return box.value
        }, set: { base.wrappedValue = $0 })
    }
}

@MainActor
final class LastValueBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension Binding: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: Binding<Value>, _ rhs: Binding<Value>) -> Bool {
        _onMainActor { lhs.location.isEqual(to: rhs.location) }
    }
}

nonisolated func runtimeWarning(_ message: @autoclosure () -> String) {
    #if DEBUG
    let text = "[SwiftUI] \(message())\n"
    FileHandle.standardError.write(text.data(using: .utf8)!)
    #endif
}
