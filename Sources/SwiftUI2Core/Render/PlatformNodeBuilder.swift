import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct RenderSnapshot: Equatable {
    var frame: CGRect
    var content: RenderContent
}

@MainActor
extension _ViewInputs {
    /// Creates a platform render node for this view plus the eager "sink" attribute that pushes its
    /// frame/content to the renderer whenever (and only when) they change.
    ///
    /// Returns render inputs for children of the node (for container nodes such as buttons,
    /// scroll views and effects).
    @discardableResult
    func makePlatformNode(
        content: Attribute<RenderContent>,
        actions: RenderActions = RenderActions(),
        childOrigin: Attribute<CGPoint>? = nil
    ) -> _RenderInputs {
        let renderer = host.renderer
        let node = renderer.makePlatformNode(path: path)
        node.animationScope = animationScope
        renderer.setActions(node, actions)
        renderer.append(node, to: render.parent)
        subgraph.onDestroy { renderer.remove(node) }

        let geometry = self.geometry
        let origin = render.origin
        let sink = Attribute<RenderSnapshot>(subgraph, isEqual: { $0 == $1 }) {
            let placed = geometry.value
            let base = origin?.value ?? .zero
            return RenderSnapshot(frame: CGRect(origin: placed.origin - base, size: placed.size), content: content.value)
        }
        sink.label = "render \(path)"
        sink.order = depth
        sink.onChange = { snapshot in
            renderer.update(node, frame: snapshot.frame, content: snapshot.content)
        }
        sink.isEager = true

        let ownOrigin = childOrigin ?? Attribute<CGPoint>(subgraph, isEqual: { $0 == $1 }) { geometry.value.origin }
        return _RenderInputs(parent: node, origin: ownOrigin)
    }

    /// A constant attribute in this view's subgraph.
    func constant<T>(_ value: T) -> Attribute<T> {
        Attribute(subgraph, value: value)
    }
}
