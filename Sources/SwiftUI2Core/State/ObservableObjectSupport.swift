import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Observation

#if canImport(Combine) && !SWIFTUI2_COMBINE_SHIM
@_exported import Combine
#endif

/// Shared subscription logic for `@ObservedObject`, `@StateObject` and `@EnvironmentObject`:
/// `objectWillChange` invalidates the owning body attribute (every view observing the object
/// updates, regardless of which property changed — exactly SwiftUI's ObservableObject semantics).
@MainActor
final class ObjectSubscription {
    private(set) weak var object: AnyObject?
    private var cancellable: AnyCancellable?

    func observe<O: ObservableObject>(_ object: O, context: DynamicPropertyContext) {
        if self.object === object, cancellable != nil { return }
        self.object = object
        let owner = context.owner
        cancellable = object.objectWillChange.sink { [weak owner] _ in
            invalidateOnMain(owner)
        }
    }
}

// MARK: - @ObservedObject

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject>: DynamicProperty {
    @dynamicMemberLookup
    public struct Wrapper {
        let root: ObjectType
        @MainActor public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            Binding(location: ObjectLocation(root: root, keyPath: keyPath))
        }
    }

    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public init(initialValue: ObjectType) { self.wrappedValue = initialValue }

    public var projectedValue: Wrapper { Wrapper(root: wrappedValue) }
}

extension ObservedObject: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        let subscription = (slot as? ObjectSubscription) ?? ObjectSubscription()
        slot = subscription
        subscription.observe(wrappedValue, context: context)
    }
}

extension ObservedObject: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: ObservedObject, _ rhs: ObservedObject) -> Bool {
        MainActor.assumeIsolated { lhs.wrappedValue === rhs.wrappedValue }
    }
}

// MARK: - @StateObject

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject>: DynamicProperty {
    let thunk: () -> ObjectType
    var object: ObjectType?
    /// Holds the object when used outside a view graph (e.g. in an `App`), so it is created once.
    let uninstalled = UninstalledObjectBox<ObjectType>()

    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        self.thunk = thunk
    }

    public var wrappedValue: ObjectType {
        if let object { return object }
        if let existing = uninstalled.object { return existing }
        let created = thunk()
        uninstalled.object = created
        return created
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject<ObjectType>.Wrapper(root: wrappedValue)
    }
}

final class UninstalledObjectBox<ObjectType>: @unchecked Sendable {
    var object: ObjectType?
}

@MainActor
final class StateObjectStorage<ObjectType: ObservableObject> {
    let object: ObjectType
    let subscription = ObjectSubscription()
    init(object: ObjectType) { self.object = object }
}

extension StateObject: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        let storage: StateObjectStorage<ObjectType>
        if let existing = slot as? StateObjectStorage<ObjectType> {
            storage = existing
        } else {
            // Created once per view identity, lazily, on first install (like SwiftUI).
            storage = StateObjectStorage(object: AnyAttribute.withoutDependencies { thunk() })
            slot = storage
        }
        object = storage.object
        storage.subscription.observe(storage.object, context: context)
    }
}

extension StateObject: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: StateObject, _ rhs: StateObject) -> Bool { true }
}

// MARK: - @EnvironmentObject

@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject>: DynamicProperty {
    @dynamicMemberLookup
    public struct Wrapper {
        let root: ObjectType
        @MainActor public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            Binding(location: ObjectLocation(root: root, keyPath: keyPath))
        }
    }

    var attribute: Attribute<ObjectType?>?

    public init() {}

    public var wrappedValue: ObjectType {
        guard let object = attribute?.value else {
            fatalError("No ObservableObject of type \(ObjectType.self) found. A View.environmentObject(_:) for \(ObjectType.self) may be missing as an ancestor of this view.")
        }
        return object
    }

    public var projectedValue: Wrapper { Wrapper(root: wrappedValue) }
}

@MainActor
final class EnvironmentObjectStorage<ObjectType: ObservableObject> {
    let attribute: Attribute<ObjectType?>
    let subscription = ObjectSubscription()
    init(attribute: Attribute<ObjectType?>) { self.attribute = attribute }
}

extension EnvironmentObject: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        let storage: EnvironmentObjectStorage<ObjectType>
        if let existing = slot as? EnvironmentObjectStorage<ObjectType> {
            storage = existing
        } else {
            let environment = context.environment
            let attribute = Attribute<ObjectType?>(context.subgraph) { environment.value[object: ObjectType.self] }
            storage = EnvironmentObjectStorage(attribute: attribute)
            slot = storage
        }
        attribute = storage.attribute
        if let object = storage.attribute.value {
            storage.subscription.observe(object, context: context)
        }
    }
}

extension EnvironmentObject: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: EnvironmentObject, _ rhs: EnvironmentObject) -> Bool { true }
}

// MARK: - @Bindable

@propertyWrapper @dynamicMemberLookup
public struct Bindable<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) where Value: AnyObject & Observable {
        self.wrappedValue = wrappedValue
    }

    public init(_ wrappedValue: Value) where Value: AnyObject & Observable {
        self.wrappedValue = wrappedValue
    }

    public init(projectedValue: Bindable<Value>) {
        self = projectedValue
    }

    public var projectedValue: Bindable<Value> { self }

    @MainActor
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> where Value: AnyObject {
        Binding(location: ObjectLocation(root: wrappedValue, keyPath: keyPath))
    }
}
