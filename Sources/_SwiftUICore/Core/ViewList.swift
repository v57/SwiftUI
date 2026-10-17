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

/// A flattened view list: identities and element factories in order (lazy containers keep it
/// while only the visible part changes).
@MainActor
final class FlatViewList {
    let ids: [ViewListID]
    let elements: [ViewListElement]

    init(_ flat: [(ViewListID, ViewListElement)]) {
        ids = flat.map(\.0)
        elements = flat.map(\.1)
    }

    var count: Int { ids.count }
    subscript(index: Int) -> (ViewListID, ViewListElement) { (ids[index], elements[index]) }
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
    /// Lazy containers isolate every item; eager ones once they have this many children.
    let isolationThreshold: Int
    static let eagerIsolationThreshold = 16

    init(list: ViewList, inputs: _ViewInputs, childAxis: Axis?, filter: (@MainActor (FlatViewList) -> [(ViewListID, ViewListElement)])? = nil) {
        self.inputs = inputs
        self.isolationThreshold = filter == nil ? Self.eagerIsolationThreshold : 0
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
        items.setLabel("items \(inputs.path)")
        items.order = inputs.depth
        self.items = items
        let isStatic = list.isStatic
        if let filter {
            // A filtered (lazy) container keeps the flattened list in its own attribute: it changes
            // with the list only, while the filter (the viewport) changes on every scroll step.
            let flatList = Attribute<FlatViewList>(inputs.subgraph, isEqual: { $0.ids == $1.ids }) {
                var flat: [(ViewListID, ViewListElement)] = []
                list.flatten(into: &flat)
                inputs.tracer.counters.listElementVisits += flat.count
                return FlatViewList(flat)
            }
            flatList.setLabel("flat list \(inputs.path)")
            items.setRule { [unowned self] in
                let flat = flatList.value
                if !isStatic { self.inputs.tracer.record(.listUpdate, self.inputs.path) }
                return self.reconcile(filter(flat), childAxis: childAxis)
            }
        } else {
            items.setRule { [unowned self] in
                var flat: [(ViewListID, ViewListElement)] = []
                list.flatten(into: &flat)
                self.inputs.tracer.counters.listElementVisits += flat.count
                if !isStatic { self.inputs.tracer.record(.listUpdate, self.inputs.path) }
                return self.reconcile(flat, childAxis: childAxis)
            }
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
                let isolated = flat.count >= isolationThreshold && !ownsRenderMembership
                result.append(makeItem(id: id, element: element, childAxis: childAxis, isolated: isolated))
            }
        }
        for (id, item) in live where !seen.contains(id) {
            item.subgraph.destroy()
        }
        var newLive: [ViewListID: Item] = [:]
        newLive.reserveCapacity(result.count)
        var zIndices: [Double] = []
        zIndices.reserveCapacity(result.count)
        var hasZIndex = false
        var groups: [RenderNode] = []
        groups.reserveCapacity(result.count)
        for item in result {
            newLive[item.id] = item
            let zIndex = item.traits.value(ZIndexTraitKey.self)
            zIndices.append(zIndex)
            if zIndex != 0 { hasZIndex = true }
            groups.append(item.group)
        }
        live = newLive
        indexByID = newIndex
        if ownsRenderMembership {
            // membership attribute updates the render group
        } else if hasZIndex {
            let ordered = sortedByZIndex(groups, zIndices)
            inputs.host.renderer.setChildren(of: group, ordered)
        } else {
            inputs.host.renderer.setChildren(of: group, groups)
        }
        return result
    }

    private nonisolated func sortedByZIndex(_ groups: [RenderNode], _ zIndices: [Double]) -> [RenderNode] {
        groups.indices.sorted { (zIndices[$0], $0) < (zIndices[$1], $1) }.map { groups[$0] }
    }

    private func makeItem(id: ViewListID, element: ViewListElement, childAxis: Axis?, isolated: Bool) -> Item {
        let subgraph = inputs.subgraph.makeChild()
        let renderer = inputs.host.renderer
        let itemGroup = renderer.makeGroup(path: inputs.path)
        var childInputs = inputs
        childInputs.subgraph = subgraph
        childInputs.depth += 1
        childInputs.stackAxis = childAxis
        childInputs.render = _RenderInputs(parent: itemGroup, origin: inputs.render.origin)
        let geometry = Attribute<ViewGeometry>(subgraph, isEqual: { $0 == $1 })
        geometry.setLabel("geometry \(id)")
        childInputs.geometry = geometry
        if isolated { isolate(&childInputs, placed: geometry, group: itemGroup) }
        childInputs.listItemPosition = Attribute<ListItemPosition>(subgraph, isEqual: { $0 == $1 }) { [unowned self] in
            let items = self.items.value
            guard let index = self.indexByID[id] else { return ListItemPosition() }
            @MainActor func role(_ i: Int) -> ListElementRole? {
                items.indices.contains(i) ? items[i].traits.value(ListElementRoleKey.self) : nil
            }
            return ListItemPosition(index: index, count: items.count, previous: role(index - 1), next: role(index + 1), first: role(0))
        }
        let outputs = element.make(childInputs)
        let tracer = inputs.tracer
        let pathBox = PathBox()
        geometry.setRule { [unowned self] in
            guard let index = self.index(of: id), let placement = self.placement else { return geometry.peekValue ?? .zero }
            return placement(index)
        }
        geometry.onChange = { _ in tracer.record(.geometry, pathBox.path) }
        if let targets = inputs.scrollTargets, let key = id.lastExplicit {
            let spaceOrigin = inputs.spaceOrigin
            targets.register(key) { [weak geometry] in
                guard let frame = geometry?.peekValue?.frame else { return nil }
                let origin = spaceOrigin?.peekValue ?? .zero
                return frame.offsetBy(dx: origin.x, dy: origin.y)
            }
            subgraph.onDestroy { [weak targets] in targets?.unregister(key) }
        }
        pathBox.path = inputs.path.appending(id.description)
        return Item(id: id, subgraph: subgraph, outputs: outputs, geometry: geometry, group: itemGroup, traits: element.traits)
    }

    /// Makes an item start its own geometry space: a platform container node at the item's
    /// placement, and the item's views laid out from origin zero inside it. When the item moves (a
    /// view above it was built or grew), its container moves and nothing inside it is placed,
    /// framed or rendered again; without this a build in a long page shifted every built view
    /// below it, one by one.
    private func isolate(_ childInputs: inout _ViewInputs, placed: Attribute<ViewGeometry>, group: RenderNode) {
        let subgraph = childInputs.subgraph
        var nodeInputs = childInputs
        nodeInputs.accessibility = nil
        let zero = nodeInputs.constant(CGPoint.zero)
        let render = nodeInputs.makePlatformNode(content: nodeInputs.constant(RenderContent.effect(.group)), childOrigin: zero)
        render.parent.forwardsTransitions = true
        childInputs.render = render
        childInputs.geometry = Attribute<ViewGeometry>(subgraph, isEqual: { $0 == $1 }) {
            let item = placed.value
            return ViewGeometry(origin: .zero, size: item.size, proposal: item.proposal)
        }
        let origin = Attribute<CGPoint>(subgraph, isEqual: { $0 == $1 }) { placed.value.origin }
        // Global and named coordinate spaces see the item's origin as a translation.
        childInputs.coordinateSpaces = CoordinateSpaces(scrollTransform: origin, parent: childInputs.coordinateSpaces)
        let outer = childInputs.spaceOrigin
        childInputs.spaceOrigin = Attribute<CGPoint>(subgraph, isEqual: { $0 == $1 }) {
            let base = outer?.value ?? .zero
            let point = origin.value
            return CGPoint(x: base.x + point.x, y: base.y + point.y)
        }
        if let viewport = childInputs.scrollViewport {
            childInputs.scrollViewport = Attribute<CGRect>(subgraph, isEqual: { $0 == $1 }) {
                let point = origin.value
                return viewport.value.offsetBy(dx: -point.x, dy: -point.y)
            }
        }
    }

    /// Current index of a child (reads the item list, so geometry follows structural changes).
    func index(of id: ViewListID) -> Int? {
        _ = items.value
        return indexByID[id]
    }
}

/// A list element's kind (sections flatten into header / rows / footer).
public enum ListElementRole: Hashable, Sendable {
    case row, header, footer, sectionGap
    /// A list-provided leading row (a sidebar list's search field).
    case accessory
}

public enum ListElementRoleKey: _ViewTraitKey {
    public static var defaultValue: ListElementRole { .row }
}

/// Where a child sits in its container (list chrome such as separators depends on neighbours).
struct ListItemPosition: Equatable {
    var index = 0
    var count = 0
    var previous: ListElementRole?
    var next: ListElementRole?
    /// The container's first element (list stripes count from a leading header).
    var first: ListElementRole?
}

@MainActor
final class PathBox {
    var path: ViewPath?
}
