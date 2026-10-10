import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Trait keys

/// `.tag(_:)` — identifies an element for Picker / List / TabView selection.
public enum TagTraitKey: _ViewTraitKey {
    public static var defaultValue: AnyHashable? { nil }
}

public enum ZIndexTraitKey: _ViewTraitKey {
    public static var defaultValue: Double { 0 }
}

public enum TabItemTraitKey: _ViewTraitKey {
    public static var defaultValue: AnyView? { nil }
}

public enum GridCellColumnsTraitKey: _ViewTraitKey {
    public static var defaultValue: Int { 1 }
}

public enum GridCellUnsizedAxesTraitKey: _ViewTraitKey {
    public static var defaultValue: Axis.Set { [] }
}

public enum GridColumnAlignmentTraitKey: _ViewTraitKey {
    public static var defaultValue: HorizontalAlignment? { nil }
}

/// Where a grid cell's content sits in its cell (`gridCellAnchor`).
public enum GridCellAnchorTraitKey: _ViewTraitKey {
    public static var defaultValue: UnitPoint? { nil }
}

public enum ListRowBackgroundTraitKey: _ViewTraitKey {
    public static var defaultValue: AnyView? { nil }
}

public enum DeleteActionTraitKey: _ViewTraitKey {
    public static var defaultValue: (@MainActor (IndexSet) -> Void)? { nil }
}

/// Writes a trait on every element of the content when used in a list context; no effect in a
/// unary context (like SwiftUI).
public struct _TraitWritingModifier<Key: _ViewTraitKey>: ViewModifier {
    let value: Key.Value
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(inputs)
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        let content = body(inputs)
        let value = Attribute<Key.Value>(inputs.subgraph) { modifier.attribute.value.value }
        let list = content.list.mapElements(in: inputs.subgraph) { element in
            var copy = element
            copy.traits[Key.self] = value
            return copy
        }
        return _ViewListOutputs(list: list)
    }
}

extension View {
    public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View {
        modifier(_TraitWritingModifier<TagTraitKey>(value: AnyHashable(tag)))
    }

    public func zIndex(_ value: Double) -> some View {
        modifier(_TraitWritingModifier<ZIndexTraitKey>(value: value))
    }

    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        modifier(_TraitWritingModifier<TabItemTraitKey>(value: AnyView(label())))
    }

    public func gridCellColumns(_ count: Int) -> some View {
        modifier(_TraitWritingModifier<GridCellColumnsTraitKey>(value: count))
    }

    public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View {
        modifier(_TraitWritingModifier<GridCellUnsizedAxesTraitKey>(value: axes))
    }

    public func gridCellAnchor(_ anchor: UnitPoint) -> some View {
        modifier(_TraitWritingModifier<GridCellAnchorTraitKey>(value: anchor))
    }

    public func gridColumnAlignment(_ alignment: HorizontalAlignment) -> some View {
        modifier(_TraitWritingModifier<GridColumnAlignmentTraitKey>(value: alignment))
    }

    public func listRowBackground<V: View>(_ view: V?) -> some View {
        modifier(_TraitWritingModifier<ListRowBackgroundTraitKey>(value: view.map { AnyView($0) }))
    }
}

/// Selection values compare through `AnyHashable`, looking through optionals (so a `String?`
/// selection matches `.tag("a")`).
func selectionMatches(_ selection: AnyHashable?, _ tag: AnyHashable?) -> Bool {
    guard let selection, let tag else { return selection == nil && tag == nil }
    if selection == tag { return true }
    return unwrapOptional(selection) == unwrapOptional(tag)
}

private func unwrapOptional(_ value: AnyHashable) -> AnyHashable? {
    let base = value.base
    let mirror = Mirror(reflecting: base)
    guard mirror.displayStyle == .optional else { return value }
    guard let child = mirror.children.first else { return nil }
    return child.value as? AnyHashable
}

// MARK: - Filtering lists by trait

extension ViewList {
    /// A dynamic list keeping only elements whose tag matches `selection()` (TabView, Picker labels).
    @MainActor
    func filtered(in subgraph: Subgraph, selection: @escaping @MainActor () -> AnyHashable?) -> ViewList {
        let source = self
        let attribute = makeObservedAttribute(subgraph, of: ViewList.self, isEqual: { lhs, rhs in
            ViewList.isStructurallyEqual(lhs, rhs) && lhs.debugIDs == rhs.debugIDs
        }) {
            var flat: [(ViewListID, ViewListElement)] = []
            source.flatten(into: &flat)
            let current = selection()
            let kept = flat.filter { selectionMatches(current, $0.1.traits.value(TagTraitKey.self)) }
            var list = ViewList(nodes: kept.map { .nested(.explicit(AnyHashable($0.0)), ViewList(element: $0.1)) })
            list.debugIDs = kept.map(\.0)
            return list
        }
        return ViewList(nodes: [.dynamic(nil, attribute)])
    }
}
