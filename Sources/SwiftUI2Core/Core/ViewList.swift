import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Identity of an element inside a flattened view list: the path of tuple indices, `ForEach` ids
/// and conditional branches that lead to it. Mirrors SwiftUI's structural + explicit identity.
public struct ViewListID: Hashable, CustomStringConvertible {
    public enum Component: Hashable, CustomStringConvertible {
        case index(Int)
        case explicit(AnyHashable)
        case branch(Int)

        public var description: String {
            switch self {
            case .index(let i): return "[\(i)]"
            case .explicit(let id): return "#\(id)"
            case .branch(let b): return "?\(b)"
            }
        }
    }

    var components: [Component]

    init(_ components: [Component] = []) { self.components = components }

    func appending(_ component: Component) -> ViewListID { ViewListID(components + [component]) }

    public var description: String { components.map(\.description).joined() }
}

/// Factory for one unary view of a list. The closure receives placement (geometry, render parent,
/// subgraph) from the container and merges it with the list-level context it captured.
public struct ViewListElement {
    var make: @MainActor (_ViewInputs) -> _ViewOutputs
    /// Per-element values set by trait modifiers in a list context (`.tag`, grid cell spans, ...).
    var traits = ViewTraits()

    init(traits: ViewTraits = ViewTraits(), make: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) {
        self.make = make
        self.traits = traits
    }
}

/// Type-keyed trait values (each an attribute so they can change without restructuring).
public struct ViewTraits {
    var values: [ObjectIdentifier: AnyAttribute] = [:]

    subscript<K: _ViewTraitKey>(key: K.Type) -> Attribute<K.Value>? {
        get { values[ObjectIdentifier(key)] as? Attribute<K.Value> }
        set { values[ObjectIdentifier(key)] = newValue }
    }

    /// Current value (reading registers a dependency).
    @MainActor
    func value<K: _ViewTraitKey>(_ key: K.Type) -> K.Value {
        self[key]?.value ?? K.defaultValue
    }
}

public protocol _ViewTraitKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// A (possibly dynamic) list of views. Static parts are plain nodes; dynamic parts (ForEach, if,
/// id) are attributes producing nested lists, so a container re-diffs only when they change.
public struct ViewList {
    indirect enum Node {
        case element(ViewListElement)
        case nested(ViewListID.Component?, ViewList)
        case dynamic(ViewListID.Component?, Attribute<ViewList>)
    }

    var nodes: [Node]
    /// Identities of a filtered list (used for equality of derived lists).
    var debugIDs: [ViewListID] = []

    init(nodes: [Node]) { self.nodes = nodes }
    init(element: ViewListElement) { self.nodes = [.element(element)] }

    /// The single element, if the list is static and contains exactly one view.
    var staticSingleElement: ViewListElement? {
        guard nodes.count == 1 else { return nil }
        switch nodes[0] {
        case .element(let element): return element
        case .nested(_, let list): return list.staticSingleElement
        case .dynamic: return nil
        }
    }

    var isStatic: Bool {
        nodes.allSatisfy {
            switch $0 {
            case .element: return true
            case .nested(_, let list): return list.isStatic
            case .dynamic: return false
            }
        }
    }

    /// Flattens the list, reading dynamic attributes (and thus depending on them).
    @MainActor
    func flatten(prefix: ViewListID = ViewListID(), into result: inout [(ViewListID, ViewListElement)]) {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .element(let element):
                // Single-element lists keep the parent's identity; siblings are disambiguated by index.
                result.append((nodes.count == 1 ? prefix : prefix.appending(.index(index)), element))
            case .nested(let component, let list):
                list.flatten(prefix: component.map { prefix.appending($0) } ?? prefix, into: &result)
            case .dynamic(let component, let attribute):
                attribute.value.flatten(prefix: component.map { prefix.appending($0) } ?? prefix, into: &result)
            }
        }
    }

    /// Applies `wrap` to every element (used by modifiers in a list context). Dynamic sub-lists get
    /// a mapping attribute created once, here.
    @MainActor
    func mapElements(in subgraph: Subgraph, _ wrap: @escaping @MainActor (ViewListElement) -> ViewListElement) -> ViewList {
        ViewList(nodes: nodes.map { node in
            switch node {
            case .element(let element):
                return .element(wrap(element))
            case .nested(let component, let list):
                return .nested(component, list.mapElements(in: subgraph, wrap))
            case .dynamic(let component, let attribute):
                let mapped = Attribute<ViewList>(subgraph, isEqual: ViewList.isStructurallyEqual) {
                    attribute.value.mapElements(in: subgraph, wrap)
                }
                return .dynamic(component, mapped)
            }
        })
    }

    /// Cheap structural equality: same shape, same identities, same dynamic attributes.
    /// Element closures are not compared — an element at the same identity is the same view.
    static func isStructurallyEqual(_ lhs: ViewList, _ rhs: ViewList) -> Bool {
        guard lhs.nodes.count == rhs.nodes.count else { return false }
        for (l, r) in zip(lhs.nodes, rhs.nodes) {
            switch (l, r) {
            case (.element, .element):
                continue
            case let (.nested(lc, ll), .nested(rc, rl)):
                if lc != rc || !isStructurallyEqual(ll, rl) { return false }
            case let (.dynamic(lc, la), .dynamic(rc, ra)):
                if lc != rc || la !== ra { return false }
            default:
                return false
            }
        }
        return true
    }
}

/// Instantiates the elements of a `ViewList` as unary child views, keyed by identity.
/// Children appear/disappear (with their own subgraph, state and render nodes) only when their
/// identity enters or leaves the list.
@MainActor
final class ViewListContainer {
    struct Item {
        let id: ViewListID
        let subgraph: Subgraph
        let outputs: _ViewOutputs
        let geometry: Attribute<ViewGeometry>
        let group: RenderNode
        let traits: ViewTraits
    }

    let inputs: _ViewInputs
    let group: RenderNode
    private(set) var items: Attribute<[Item]>!
    private var live: [ViewListID: Item] = [:]
    private var indexByID: [ViewListID: Int] = [:]
    /// Produces the geometry of the child at an index; installed by the owning layout.
    var placement: ((Int) -> ViewGeometry)?
    /// Set when the owning layout decides which children are rendered (hidden subviews).
    var ownsRenderMembership = false

    init(list: ViewList, inputs: _ViewInputs, childAxis: Axis?, filter: (@MainActor ([(ViewListID, ViewListElement)]) -> [(ViewListID, ViewListElement)])? = nil) {
        self.inputs = inputs
        self.group = inputs.host.renderer.makeGroup(path: inputs.path)
        inputs.host.renderer.append(group, to: inputs.render.parent)
        let renderer = inputs.host.renderer
        let ownGroup = group
        // The subgraph owns the container (its attributes' rules reference it unowned).
        inputs.subgraph.onDestroy { [self] in
            renderer.remove(ownGroup)
            self.live.removeAll()
        }

        let items = Attribute<[Item]>(inputs.subgraph, isEqual: { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id }
        })
        items.label = "items \(inputs.path)"
        items.order = inputs.depth
        self.items = items
        let isStatic = list.isStatic
        items.setRule { [unowned self] in
            var flat: [(ViewListID, ViewListElement)] = []
            list.flatten(into: &flat)
            if !isStatic { self.inputs.tracer.record(.listUpdate, self.inputs.path) }
            if let filter { flat = filter(flat) }
            return self.reconcile(flat, childAxis: childAxis)
        }
        items.isEager = true
    }

    private func reconcile(_ flat: [(ViewListID, ViewListElement)], childAxis: Axis?) -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(flat.count)
        var seen = Set<ViewListID>()
        var newIndex: [ViewListID: Int] = [:]
        for (id, element) in flat {
            guard seen.insert(id).inserted else {
                // Duplicate identities: SwiftUI logs and keeps the first; do the same.
                continue
            }
            newIndex[id] = result.count
            if let existing = live[id] {
                result.append(existing)
            } else {
                result.append(makeItem(id: id, element: element, childAxis: childAxis))
            }
        }
        for (id, item) in live where !seen.contains(id) {
            item.subgraph.destroy()
        }
        live = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        indexByID = newIndex
        let zIndices = result.map { $0.traits.value(ZIndexTraitKey.self) }
        if ownsRenderMembership {
            // membership attribute updates the render group
        } else if zIndices.contains(where: { $0 != 0 }) {
            let ordered = result.indices.sorted { (zIndices[$0], $0) < (zIndices[$1], $1) }.map { result[$0].group }
            inputs.host.renderer.setChildren(of: group, ordered)
        } else {
            inputs.host.renderer.setChildren(of: group, result.map(\.group))
        }
        return result
    }

    private func makeItem(id: ViewListID, element: ViewListElement, childAxis: Axis?) -> Item {
        let subgraph = inputs.subgraph.makeChild()
        let renderer = inputs.host.renderer
        let itemGroup = renderer.makeGroup(path: inputs.path)
        var childInputs = inputs
        childInputs.subgraph = subgraph
        childInputs.depth += 1
        childInputs.stackAxis = childAxis
        childInputs.render = _RenderInputs(parent: itemGroup, origin: inputs.render.origin)
        let geometry = Attribute<ViewGeometry>(subgraph, isEqual: { $0 == $1 })
        geometry.label = "geometry \(id)"
        childInputs.geometry = geometry
        let outputs = element.make(childInputs)
        let tracer = inputs.tracer
        let pathBox = PathBox()
        geometry.setRule { [unowned self] in
            guard let index = self.index(of: id), let placement = self.placement else { return geometry.peekValue ?? .zero }
            return placement(index)
        }
        geometry.onChange = { _ in tracer.record(.geometry, pathBox.path) }
        if let targets = inputs.scrollTargets, let key = id.lastExplicit {
            targets.register(key) { [weak geometry] in geometry?.peekValue?.frame }
            subgraph.onDestroy { [weak targets] in targets?.unregister(key) }
        }
        pathBox.path = inputs.path.appending(id.description)
        return Item(id: id, subgraph: subgraph, outputs: outputs, geometry: geometry, group: itemGroup, traits: element.traits)
    }

    /// Current index of a child (reads the item list, so geometry follows structural changes).
    func index(of id: ViewListID) -> Int? {
        _ = items.value
        return indexByID[id]
    }
}

@MainActor
final class PathBox {
    var path: ViewPath?
}
