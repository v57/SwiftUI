/// A lifetime scope for attributes. Each view identity (a branch of an `if`, an element of a
/// `ForEach`, the content of an `AnyView`) owns a subgraph; destroying it tears down all attributes,
/// runs cleanups (onDisappear, render-node removal, subscriptions) and recursively destroys children.
@MainActor
public final class Subgraph {
    public let graph: AttributeGraph
    /// Not `weak`: a weak reference gives the parent a side table, which makes every retain and
    /// release of it slow. A parent clears its children's back references when it goes away.
    public var parent: Subgraph? { parentReference?.takeUnretainedValue() }
    @exclusivity(unchecked) private var parentReference: Unmanaged<Subgraph>?
    /// Children in creation order; a destroyed child leaves a hole (its slot is nil) so removing one
    /// costs O(1) however many siblings it has (a lazy stack's rows sit next to every `ForEach`
    /// element). Holes are compacted once they are half of the array.
    @exclusivity(unchecked) private var children: [Subgraph?] = []
    @exclusivity(unchecked) private var holes = 0
    /// This subgraph's index in its parent's `children`.
    @exclusivity(unchecked) private var slot = 0
    @exclusivity(unchecked) private var attributes: [AnyAttribute] = []
    @exclusivity(unchecked) private var cleanups: [() -> Void] = []
    @exclusivity(unchecked) public private(set) var isValid = true

    public init(graph: AttributeGraph) {
        self.graph = graph
    }

    private init(parent: Subgraph) {
        self.graph = parent.graph
        self.parentReference = .passUnretained(parent)
    }

    deinit {
        _assumeMainActor { for child in children { child?.parentReference = nil } }
    }

    public func makeChild() -> Subgraph {
        let child = Subgraph(parent: self)
        child.slot = children.count
        children.append(child)
        return child
    }

    private func removeChild(_ child: Subgraph) {
        guard child.slot < children.count, children[child.slot] === child else { return }
        children[child.slot] = nil
        holes += 1
        if holes > 16, holes * 2 > children.count {
            children.removeAll { $0 == nil }
            for (index, remaining) in children.enumerated() { remaining?.slot = index }
            holes = 0
        }
    }

    func register(_ attribute: AnyAttribute) {
        attributes.append(attribute)
        if !isValid { attribute.destroy() }
    }

    /// Registers a closure run (in reverse registration order) when the subgraph is destroyed.
    public func onDestroy(_ cleanup: @escaping () -> Void) {
        cleanups.append(cleanup)
    }

    public var attributeCount: Int { attributes.count }

    public func destroy() {
        guard isValid else { return }
        isValid = false
        for child in children.reversed() { child?.destroyFromParent() }
        children.removeAll()
        holes = 0
        // Newest first: an attribute is usually the latest output of its inputs, so taking it off
        // their output lists finds it at the end.
        var index = attributes.count - 1
        while index >= 0 {
            attributes[index].destroy()
            index -= 1
        }
        attributes.removeAll()
        let pending = cleanups
        cleanups.removeAll()
        for cleanup in pending.reversed() { cleanup() }
        parent?.removeChild(self)
    }

    private func destroyFromParent() {
        let saved = parentReference
        parentReference = nil
        destroy()
        parentReference = saved
    }
}
