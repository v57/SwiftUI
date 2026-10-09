/// A lifetime scope for attributes. Each view identity (a branch of an `if`, an element of a
/// `ForEach`, the content of an `AnyView`) owns a subgraph; destroying it tears down all attributes,
/// runs cleanups (onDisappear, render-node removal, subscriptions) and recursively destroys children.
@MainActor
public final class Subgraph {
    public let graph: AttributeGraph
    public private(set) weak var parent: Subgraph?
    private var children: [Subgraph] = []
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
        children.append(child)
        return child
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
        for child in children.reversed() { child.destroyFromParent() }
        children.removeAll()
        for attribute in attributes { attribute.destroy() }
        attributes.removeAll()
        let pending = cleanups
        cleanups.removeAll()
        for cleanup in pending.reversed() { cleanup() }
        if let parent {
            parent.children.removeAll { $0 === self }
        }
    }

    private func destroyFromParent() {
        let saved = parent
        parent = nil
        destroy()
        parent = saved
    }
}
