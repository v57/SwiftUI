import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Mirrors `SwiftUI.PreferenceKey`: values flow from children to ancestors.
public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

extension PreferenceKey where Value: ExpressibleByNilLiteral {
    public static var defaultValue: Value { nil }
}

/// Type-erased key used in inputs (requested keys) and outputs (produced values).
@MainActor
protocol AnyPreferenceKeyBox {
    var id: ObjectIdentifier { get }
    /// Combines `parts` (in view order) into one attribute.
    func combine(_ parts: [AnyAttribute], subgraph: Subgraph) -> AnyAttribute
    /// Combines a dynamic list of contributors.
    func combine(dynamic: @escaping @MainActor () -> [AnyAttribute], subgraph: Subgraph) -> AnyAttribute
}

struct PreferenceKeyBox<K: PreferenceKey>: AnyPreferenceKeyBox {
    var id: ObjectIdentifier { ObjectIdentifier(K.self) }

    func combine(_ parts: [AnyAttribute], subgraph: Subgraph) -> AnyAttribute {
        if parts.count == 1 { return parts[0] }
        return combine(dynamic: { parts }, subgraph: subgraph)
    }

    func combine(dynamic: @escaping @MainActor () -> [AnyAttribute], subgraph: Subgraph) -> AnyAttribute {
        Attribute<K.Value>(subgraph) {
            var result = K.defaultValue
            var first = true
            for part in dynamic() {
                let next = (part as! Attribute<K.Value>).value
                if first {
                    result = next
                    first = false
                } else {
                    K.reduce(value: &result) { next }
                }
            }
            return result
        }
    }
}

/// Preference values produced by a view, keyed by preference key type.
public struct PreferenceOutputs {
    var values: [ObjectIdentifier: AnyAttribute] = [:]

    subscript<K: PreferenceKey>(key: K.Type) -> Attribute<K.Value>? {
        get { values[ObjectIdentifier(key)] as? Attribute<K.Value> }
        set { values[ObjectIdentifier(key)] = newValue }
    }

    var isEmpty: Bool { values.isEmpty }

    /// Combines outputs of several views (in view order) for the requested keys.
    @MainActor
    static func combine(_ outputs: [PreferenceOutputs], keys: [any AnyPreferenceKeyBox], subgraph: Subgraph) -> PreferenceOutputs {
        var result = PreferenceOutputs()
        for key in keys {
            let parts = outputs.compactMap { $0.values[key.id] }
            if !parts.isEmpty { result.values[key.id] = key.combine(parts, subgraph: subgraph) }
        }
        return result
    }
}

extension _ViewInputs {
    func requests<K: PreferenceKey>(_ key: K.Type) -> Bool {
        preferenceKeys.contains { $0.id == ObjectIdentifier(key) }
    }

    func requesting<K: PreferenceKey>(_ key: K.Type) -> _ViewInputs {
        var copy = self
        if !requests(key) { copy.preferenceKeys.append(PreferenceKeyBox<K>()) }
        return copy
    }
}

// MARK: - Modifiers

public struct _PreferenceWritingModifier<Key: PreferenceKey>: ViewModifier {
    public var value: Key.Value
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var outputs = body(inputs)
        if inputs.requests(Key.self) {
            let source = modifier.attribute
            outputs.preferences[Key.self] = Attribute<Key.Value>(inputs.subgraph) { source.value.value }
        }
        return outputs
    }
}

public struct _PreferenceTransformModifier<Key: PreferenceKey>: ViewModifier {
    let transform: (inout Key.Value) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var outputs = body(inputs)
        if inputs.requests(Key.self) {
            let source = modifier.attribute
            let child = outputs.preferences[Key.self]
            outputs.preferences[Key.self] = Attribute<Key.Value>(inputs.subgraph) {
                var value = child?.value ?? Key.defaultValue
                source.value.transform(&value)
                return value
            }
        }
        return outputs
    }
}

public struct _PreferenceActionModifier<Key: PreferenceKey>: ViewModifier where Key.Value: Equatable {
    let action: @MainActor (Key.Value) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let outputs = body(inputs.requesting(Key.self))
        let host = inputs.host
        let source = modifier.attribute
        let child = outputs.preferences[Key.self]
        let observer = Attribute<Key.Value>(inputs.subgraph, isEqual: { $0 == $1 }) { child?.value ?? Key.defaultValue }
        observer.order = inputs.depth
        observer.onChange = { [weak source] value in
            guard let source else { return }
            let action = AnyAttribute.withoutDependencies { source.value.action }
            host.enqueueAfterUpdate { action(value) }
        }
        observer.isEager = true
        return outputs
    }
}

extension View {
    public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
        modifier(_PreferenceWritingModifier<K>(value: value))
    }

    public func transformPreference<K: PreferenceKey>(_ key: K.Type = K.self, _ callback: @escaping (inout K.Value) -> Void) -> some View {
        modifier(_PreferenceTransformModifier<K>(transform: callback))
    }

    public func onPreferenceChange<K: PreferenceKey>(_ key: K.Type = K.self, perform action: @escaping @MainActor (K.Value) -> Void) -> some View where K.Value: Equatable {
        modifier(_PreferenceActionModifier<K>(action: action))
    }

    public func overlayPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center, @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        modifier(_PreferenceSecondaryModifier<K, V>(transform: transform, alignment: alignment, placement: .above))
    }

    public func backgroundPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center, @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        modifier(_PreferenceSecondaryModifier<K, V>(transform: transform, alignment: alignment, placement: .below))
    }

    public func anchorPreference<A, K: PreferenceKey>(key: K.Type = K.self, value: Anchor<A>.Source, transform: @escaping (Anchor<A>) -> K.Value) -> some View {
        modifier(_AnchorPreferenceModifier<A, K>(source: value, transform: transform))
    }
}

public struct _PreferenceSecondaryModifier<Key: PreferenceKey, Secondary: View>: ViewModifier {
    let transform: (Key.Value) -> Secondary
    let alignment: Alignment
    let placement: SecondaryPlacement
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let primaryPreferences = LastValue<Attribute<Key.Value>?>()
        let secondary = Attribute<Secondary>(inputs.subgraph)
        secondary.setRule { [unowned secondary] in
            let value = primaryPreferences.value??.value ?? Key.defaultValue
            let transform = modifier.attribute.value.transform
            return observingChanges(invalidating: secondary) { transform(value) }
        }
        let alignment = Attribute<Alignment>(inputs.subgraph, isEqual: { $0 == $1 }) { modifier.attribute.value.alignment }
        let placement = AnyAttribute.withoutDependencies { modifier.attribute.value.placement }
        return makeSecondaryLayer(secondary: _GraphValue(secondary), alignment: alignment, placement: placement, inputs: inputs) { primaryInputs in
            let outputs = body(primaryInputs.requesting(Key.self))
            primaryPreferences.value = outputs.preferences[Key.self]
            return outputs
        }
    }
}

// MARK: - Anchors

public struct Anchor<Value>: @unchecked Sendable {
    let value: Value

    public struct Source: @unchecked Sendable {
        let resolve: @MainActor (ViewGeometry) -> Value
    }
}

extension Anchor: Equatable where Value: Equatable {}
extension Anchor: Hashable where Value: Hashable {}

extension Anchor.Source where Value == CGRect {
    public static var bounds: Anchor<CGRect>.Source { Anchor<CGRect>.Source { $0.frame } }
    public static func rect(_ r: CGRect) -> Anchor<CGRect>.Source {
        Anchor<CGRect>.Source { CGRect(origin: CGPoint(x: $0.origin.x + r.minX, y: $0.origin.y + r.minY), size: r.size) }
    }
}

extension Anchor.Source where Value == CGPoint {
    public static func point(_ p: CGPoint) -> Anchor<CGPoint>.Source { Anchor<CGPoint>.Source { CGPoint(x: $0.origin.x + p.x, y: $0.origin.y + p.y) } }
    public static func unitPoint(_ u: UnitPoint) -> Anchor<CGPoint>.Source {
        Anchor<CGPoint>.Source { CGPoint(x: $0.origin.x + u.x * $0.size.width, y: $0.origin.y + u.y * $0.size.height) }
    }
    public static var center: Anchor<CGPoint>.Source { unitPoint(.center) }
    public static var top: Anchor<CGPoint>.Source { unitPoint(.top) }
    public static var bottom: Anchor<CGPoint>.Source { unitPoint(.bottom) }
    public static var leading: Anchor<CGPoint>.Source { unitPoint(.leading) }
    public static var trailing: Anchor<CGPoint>.Source { unitPoint(.trailing) }
    public static var topLeading: Anchor<CGPoint>.Source { unitPoint(.topLeading) }
    public static var topTrailing: Anchor<CGPoint>.Source { unitPoint(.topTrailing) }
    public static var bottomLeading: Anchor<CGPoint>.Source { unitPoint(.bottomLeading) }
    public static var bottomTrailing: Anchor<CGPoint>.Source { unitPoint(.bottomTrailing) }
}

public struct _AnchorPreferenceModifier<A, Key: PreferenceKey>: ViewModifier {
    let source: Anchor<A>.Source
    let transform: (Anchor<A>) -> Key.Value
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var outputs = body(inputs)
        if inputs.requests(Key.self) {
            let geometry = inputs.geometry
            let source = modifier.attribute
            outputs.preferences[Key.self] = Attribute<Key.Value>(inputs.subgraph) {
                let current = source.value
                return current.transform(Anchor(value: current.source.resolve(geometry.value)))
            }
        }
        return outputs
    }
}

extension GeometryProxy {
    public subscript(anchor: Anchor<CGRect>) -> CGRect {
        anchor.value.offsetBy(dx: -geometry.origin.x, dy: -geometry.origin.y)
    }

    public subscript(anchor: Anchor<CGPoint>) -> CGPoint {
        CGPoint(x: anchor.value.x - geometry.origin.x, y: anchor.value.y - geometry.origin.y)
    }
}

// MARK: - Geometry observation

public struct _GeometryActionModifier<Value: Equatable>: ViewModifier {
    let transform: (GeometryProxy) -> Value
    let action: @MainActor (Value, Value) -> Void
    let callsInitially: Bool
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let geometry = inputs.geometry
        let spaces = inputs.coordinateSpaces
        let source = modifier.attribute
        let previous = LastValue<Value>()
        let observer = Attribute<Value>(inputs.subgraph, isEqual: { $0 == $1 }) {
            source.value.transform(GeometryProxy(geometry: geometry.value, spaces: spaces))
        }
        observer.order = inputs.depth
        observer.onChange = { [weak source] value in
            let old = previous.value
            previous.value = value
            guard let current = source?.peekValue else { return }
            if let old {
                host.enqueueAfterUpdate { current.action(old, value) }
            } else if current.callsInitially {
                host.enqueueAfterUpdate { current.action(value, value) }
            }
        }
        observer.isEager = true
        // SwiftUI: content behind onGeometryChange is no longer a direct stack child (a Divider
        // in it takes the default horizontal orientation).
        var contentInputs = inputs
        contentInputs.stackAxis = nil
        return body(contentInputs)
    }
}

public struct _CoordinateSpaceModifier: ViewModifier {
    let name: AnyHashable
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var childInputs = inputs
        let name = AnyAttribute.withoutDependencies { modifier.attribute.value.name }
        let geometry = inputs.geometry
        let origin = Attribute<CGPoint>(inputs.subgraph, isEqual: { $0 == $1 }) { geometry.value.origin }
        let size = Attribute<CGSize>(inputs.subgraph, isEqual: { $0 == $1 }) { geometry.value.size }
        childInputs.coordinateSpaces = CoordinateSpaces(name: name, origin: origin, size: size, parent: inputs.coordinateSpaces)
        return body(childInputs)
    }
}

/// Named coordinate spaces visible to a view (linked list, innermost first).
@MainActor
final class CoordinateSpaces {
    /// A named space (`.coordinateSpace(name:)`): its origin in the space it is declared in.
    let name: AnyHashable?
    let origin: Attribute<CGPoint>?
    /// A scroll view boundary: added to points inside the scroll content to get points in the
    /// space around the scroll view (scroll view origin minus content offset).
    let scrollTransform: Attribute<CGPoint>?
    let parent: CoordinateSpaces?
    /// A named space's size (`GeometryProxy.bounds(of:)`): the view's, or a scroll view's visible size.
    let size: Attribute<CGSize>?

    init(name: AnyHashable, origin: Attribute<CGPoint>, size: Attribute<CGSize>? = nil, parent: CoordinateSpaces?) {
        self.name = name
        self.origin = origin
        self.scrollTransform = nil
        self.parent = parent
        self.size = size
    }

    init(scrollTransform: Attribute<CGPoint>, parent: CoordinateSpaces?) {
        self.name = nil
        self.origin = nil
        self.scrollTransform = scrollTransform
        self.parent = parent
        self.size = nil
    }

    /// The named space's bounds in the current space (nil: unknown name or no size).
    func bounds(of name: AnyHashable) -> CGRect? {
        var total = CGPoint.zero
        var current: CoordinateSpaces? = self
        while let space = current {
            if let spaceName = space.name, spaceName == name, let origin = space.origin {
                guard let size = space.size else { return nil }
                let point = origin.value
                return CGRect(origin: CGPoint(x: point.x - total.x, y: point.y - total.y), size: size.value)
            }
            if let transform = space.scrollTransform {
                let value = transform.value
                total.x += value.x
                total.y += value.y
            }
            current = space.parent
        }
        return nil
    }

    /// Offset converting a point in the current space to the named space (nil: unknown name).
    func offset(to name: AnyHashable) -> CGPoint? {
        var total = CGPoint.zero
        var current: CoordinateSpaces? = self
        while let space = current {
            if let spaceName = space.name, spaceName == name, let origin = space.origin {
                let point = origin.value
                return CGPoint(x: total.x - point.x, y: total.y - point.y)
            }
            if let transform = space.scrollTransform {
                let value = transform.value
                total.x += value.x
                total.y += value.y
            }
            current = space.parent
        }
        return nil
    }

    /// Offset converting a point in the current space to the window (host) space.
    func globalOffset() -> CGPoint {
        var total = CGPoint.zero
        var current: CoordinateSpaces? = self
        while let space = current {
            if let transform = space.scrollTransform {
                let value = transform.value
                total.x += value.x
                total.y += value.y
            }
            current = space.parent
        }
        return total
    }
}

extension View {
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping @MainActor (T) -> Void) -> some View {
        modifier(_GeometryActionModifier(transform: transform, action: { _, new in action(new) }, callsInitially: true))
    }

    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping @MainActor (T, T) -> Void) -> some View {
        modifier(_GeometryActionModifier(transform: transform, action: action, callsInitially: false))
    }

    public func coordinateSpace<N: Hashable>(name: N) -> some View {
        modifier(_CoordinateSpaceModifier(name: AnyHashable(name)))
    }

    public func coordinateSpace(_ space: NamedCoordinateSpace) -> some View {
        modifier(_CoordinateSpaceModifier(name: space.name))
    }
}

public struct NamedCoordinateSpace: Hashable, @unchecked Sendable {
    let name: AnyHashable
}


