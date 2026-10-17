/// A lifetime scope for attributes. Each view identity (a branch of an `if`, an element of a
/// `ForEach`, the content of an `AnyView`) owns a subgraph; destroying it tears down all attributes,
/// runs cleanups (onDisappear, render-node removal, subscriptions) and recursively destroys children.
@MainActor
public final class Subgraph {
    public let graph: AttributeGraph
    public private(set) weak var parent: Subgraph?
    /// Children in creation order; a destroyed child leaves a hole (its slot is nil) so removing one
    /// costs O(1) however many siblings it has (a lazy stack's rows sit next to every `ForEach`
    /// element). Holes are compacted once they are half of the array.
    private var children: [Subgraph?] = []
    private var holes = 0
    /// This subgraph's index in its parent's `children`.
    private var slot = 0
    private var attributes: [AnyAttribute] = []
    private var cleanups: [() -> Void] = []
    public private(set) var isValid = true

    public init(graph: AttributeGraph) {
        self.graph = graph
    }

    private init(parent: Subgraph) {
        self.graph = parent.graph
        self.parent = parent
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
        for attribute in attributes { attribute.destroy() }
        attributes.removeAll()
        let pending = cleanups
        cleanups.removeAll()
        for cleanup in pending.reversed() { cleanup() }
        parent?.removeChild(self)
    }

    private func destroyFromParent() {
        let saved = parent
        parent = nil
        destroy()
        parent = saved
    }
}
