import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Observation

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Persistent (copy-on-write by sharing) list of environment values, like SwiftUI's PropertyList.
/// Writing pushes a node; equality is node identity, so an unchanged environment is O(1) to compare.
public struct EnvironmentValues: CustomStringConvertible {
    final class Node: @unchecked Sendable {
        let key: ObjectIdentifier
        let value: Any
        let next: Node?
        init(key: ObjectIdentifier, value: Any, next: Node?) {
            self.key = key
            self.value = value
            self.next = next
        }
    }

    var head: Node?

    public init() {}

    func lookup(_ key: ObjectIdentifier) -> Any? {
        var node = head
        while let current = node {
            if current.key == key { return current.value }
            node = current.next
        }
        return nil
    }

    mutating func store(_ key: ObjectIdentifier, _ value: Any) {
        head = Node(key: key, value: value, next: head)
    }

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { (lookup(ObjectIdentifier(key)) as? K.Value) ?? K.defaultValue }
        set { store(ObjectIdentifier(key), newValue) }
    }

    /// Objects injected with `.environment(object)` / `.environmentObject(object)`, keyed by type.
    subscript<T: AnyObject>(object type: T.Type) -> T? {
        get { lookup(ObjectIdentifier(ObjectKey<T>.self)) as? T }
        set { store(ObjectIdentifier(ObjectKey<T>.self), newValue as Any) }
    }

    private enum ObjectKey<T> {}

    public var description: String {
        var count = 0
        var node = head
        while let current = node {
            count += 1
            node = current.next
        }
        return "EnvironmentValues(\(count) entries)"
    }
}

extension EnvironmentValues: _GraphComparable {
    public static func _isIdentical(_ lhs: EnvironmentValues, _ rhs: EnvironmentValues) -> Bool {
        lhs.head === rhs.head
    }
}

// MARK: - @Environment

@propertyWrapper
public struct Environment<Value>: DynamicProperty {
    enum Content {
        case reader(@MainActor (EnvironmentValues) -> Value)
        case installed(Attribute<Value>)
    }

    var content: Content

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        content = .reader { $0[keyPath: keyPath] }
    }

    public var wrappedValue: Value {
        switch content {
        case .installed(let attribute):
            return attribute.value
        case .reader(let reader):
            if let ambient = EnvironmentValues.ambient { return reader(ambient) }
            runtimeWarning("Accessing Environment's value outside of being installed on a View. This will always read the default value.")
            return reader(EnvironmentValues())
        }
    }
}

extension Environment where Value: AnyObject & Observable {
    /// `@Environment(Model.self)` — reads an `@Observable` object injected with `.environment(_:)`.
    public init(_ objectType: Value.Type) {
        content = .reader { environment in
            guard let object = environment[object: Value.self] else {
                fatalError("No Observable object of type \(Value.self) found. A View.environment(_:) for \(Value.self) may be missing as an ancestor of this view.")
            }
            return object
        }
    }
}

extension Environment {
    public init<T: AnyObject & Observable>(_ objectType: T.Type) where Value == T? {
        content = .reader { $0[object: T.self] }
    }
}

extension Environment: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let storage = slot as? EnvironmentStorage<Value> {
            content = .installed(storage.attribute)
            return
        }
        guard case .reader(let reader) = content else { return }
        let environment = context.environment
        // Per-property projection with equality cut-off: body only depends on *this* key.
        let attribute = Attribute<Value>(context.subgraph) { reader(environment.value) }
        attribute.setLabel("environment \(context.path)")
        slot = EnvironmentStorage(attribute: attribute)
        content = .installed(attribute)
    }
}

extension Environment: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: Environment<Value>, _ rhs: Environment<Value>) -> Bool { true }
}

@MainActor
final class EnvironmentStorage<Value> {
    let attribute: Attribute<Value>
    init(attribute: Attribute<Value>) { self.attribute = attribute }
}

// MARK: - Built-in keys

struct FontKey: EnvironmentKey { static let defaultValue: Font? = nil }
struct ForegroundStyleKey: EnvironmentKey { static let defaultValue: AnyShapeStyle? = nil }
struct TintKey: EnvironmentKey { static let defaultValue: Color? = nil }
struct ColorSchemeKey: EnvironmentKey { static let defaultValue: ColorScheme = .light }
struct IsEnabledKey: EnvironmentKey { static let defaultValue = true }
struct LineLimitKey: EnvironmentKey { static let defaultValue: Int? = nil }
struct MinimumLineLimitKey: EnvironmentKey { static let defaultValue: Int? = nil }
struct MultilineTextAlignmentKey: EnvironmentKey { static let defaultValue: TextAlignment = .leading }
struct LayoutDirectionKey: EnvironmentKey { static let defaultValue: LayoutDirection = .leftToRight }
struct ButtonStyleKey: EnvironmentKey { static let defaultValue: ButtonStyleKind = .automatic }
struct ToggleStyleKey: EnvironmentKey { static let defaultValue: ToggleStyleKind = .automatic }
struct DisplayScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 2 }

extension EnvironmentValues {
    public var font: Font? {
        get { self[FontKey.self] }
        set { self[FontKey.self] = newValue }
    }

    public var colorScheme: ColorScheme {
        get { self[ColorSchemeKey.self] }
        set { self[ColorSchemeKey.self] = newValue }
    }

    public var isEnabled: Bool {
        get { self[IsEnabledKey.self] }
        set { self[IsEnabledKey.self] = newValue }
    }

    public var lineLimit: Int? {
        get { self[LineLimitKey.self] }
        set { self[LineLimitKey.self] = newValue }
    }

    /// Lower bound of `lineLimit(_: ClosedRange<Int>)` / `lineLimit(_:reservesSpace:)`: vertical
    /// text fields reserve at least this many lines.
    var minimumLineLimit: Int? {
        get { self[MinimumLineLimitKey.self] }
        set { self[MinimumLineLimitKey.self] = newValue }
    }

    public var multilineTextAlignment: TextAlignment {
        get { self[MultilineTextAlignmentKey.self] }
        set { self[MultilineTextAlignmentKey.self] = newValue }
    }

    public var layoutDirection: LayoutDirection {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }

    public var displayScale: CGFloat {
        get { self[DisplayScaleKey.self] }
        set { self[DisplayScaleKey.self] = newValue }
    }

    var foregroundStyle: AnyShapeStyle? {
        get { self[ForegroundStyleKey.self] }
        set { self[ForegroundStyleKey.self] = newValue }
    }

    var tint: Color? {
        get { self[TintKey.self] }
        set { self[TintKey.self] = newValue }
    }

    var buttonStyle: ButtonStyleKind {
        get { self[ButtonStyleKey.self] }
        set { self[ButtonStyleKey.self] = newValue }
    }

    var toggleStyle: ToggleStyleKind {
        get { self[ToggleStyleKey.self] }
        set { self[ToggleStyleKey.self] = newValue }
    }
}

// MARK: - Macros

@attached(accessor) @attached(peer, names: prefixed(__Key_))
public macro Entry() = #externalMacro(module: "SwiftUIMacros", type: "EntryMacro")

@freestanding(declaration)
public macro Preview(_ name: String? = nil, body: @escaping @MainActor () -> Any) = #externalMacro(module: "SwiftUIMacros", type: "PreviewMacro")

@freestanding(declaration)
public macro Preview(_ name: String? = nil, traits: Any..., body: @escaping @MainActor () -> Any) = #externalMacro(module: "SwiftUIMacros", type: "PreviewMacro")

@attached(peer)
public macro Previewable() = #externalMacro(module: "SwiftUIMacros", type: "PreviewableMacro")

extension EnvironmentValues {
    /// Environment seen by uninstalled `@Environment` properties (menu bar commands).
    @MainActor static var ambient: EnvironmentValues?

    @MainActor
    static func withAmbient<R>(_ environment: EnvironmentValues, _ body: () -> R) -> R {
        let previous = ambient
        ambient = environment
        defer { ambient = previous }
        return body()
    }
}
