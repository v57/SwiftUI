import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Transition / animation presentation state applied on top of a platform view's frame.
public struct RenderPresentation: Equatable, Sendable {
    public var opacity: Double = 1
    public var scale = CGSize(width: 1, height: 1)
    /// Anchor of `scale` / `rotationDegrees` in unit coordinates of the view.
    public var anchor = UnitPoint.center
    public var offset = CGSize.zero
    public var rotationDegrees: Double = 0

    public static let identity = RenderPresentation()
    public var isIdentity: Bool { self == .identity }

    init() {}

    init(effect: AnyTransition.Effect, size: CGSize) {
        opacity = effect.opacity
        scale = effect.scale
        anchor = effect.scaleAnchor
        offset = CGSize(width: effect.offset.width + effect.relativeOffset.width * size.width,
                        height: effect.offset.height + effect.relativeOffset.height * size.height)
        rotationDegrees = effect.rotationDegrees
    }

    static func interpolate(_ a: RenderPresentation, _ b: RenderPresentation, _ t: Double) -> RenderPresentation {
        var result = b
        result.opacity = a.opacity + (b.opacity - a.opacity) * t
        result.scale = CGSize(width: lerp(a.scale.width, b.scale.width, t), height: lerp(a.scale.height, b.scale.height, t))
        result.offset = CGSize(width: lerp(a.offset.width, b.offset.width, t), height: lerp(a.offset.height, b.offset.height, t))
        result.rotationDegrees = a.rotationDegrees + (b.rotationDegrees - a.rotationDegrees) * t
        result.anchor = a.isIdentity ? b.anchor : a.anchor
        return result
    }
}

/// A node of the render tree. `group` nodes are layout-only and have no platform view; their
/// children are flattened into the nearest platform ancestor. `platform` nodes map 1:1 to a
/// backend view (NSView, GtkWidget, FrameworkElement, android.view.View).
@MainActor
public final class RenderNode {
    public enum Kind { case root, group, platform }

    public let kind: Kind
    public let path: ViewPath?
    /// Content currently presented (interpolated while animating).
    public internal(set) var content: RenderContent = .empty
    /// Frame currently presented, relative to the nearest platform ancestor.
    public internal(set) var frame: CGRect = .zero
    public internal(set) var presentation = RenderPresentation.identity
    public internal(set) var children: [RenderNode] = []
    public internal(set) weak var parent: RenderNode?
    public internal(set) var actions = RenderActions()
    /// Accessibility properties attached by accessibility modifiers.
    public internal(set) var accessibility: AccessibilityProperties?
    /// Backend view. Backends own its type.
    public var handle: AnyObject?
    /// The children's views as last given to the backend (a container's), for incremental syncs.
    var syncedChildren: [AnyObject] = []

    var targetContent: RenderContent = .empty
    var targetFrame: CGRect = .zero
    var animationScope: AnimationScope?
    /// Set on group nodes created by `.transition`.
    var transition: AnyTransition?
    /// Set on group nodes created by `.matchedGeometryEffect`.
    var matchKey: AnyHashable?
    var isRemoved = false
    var needsContent = false
    var needsFrame = false
    var isPending = false
    var animation: NodeAnimation?
    var transitionAnimation: TransitionAnimation?
    /// While the backend applies content that can't be interpolated, the animation of the change
    /// (backends run content transitions, e.g. a cross-fade, with it).
    public internal(set) var contentAnimation: Animation?

    init(kind: Kind, path: ViewPath?) {
        self.kind = kind
        self.path = path
    }

    /// Nearest ancestor that owns a platform view (or the root).
    var platformAncestor: RenderNode? {
        var node = parent
        while let current = node {
            if current.kind != .group { return current }
            node = current.parent
        }
        return nil
    }

    /// Platform descendants as the backend sees them, in z-order (groups flattened).
    public var platformChildren: [RenderNode] {
        var result: [RenderNode] = []
        func visit(_ node: RenderNode) {
            for child in node.children {
                if child.kind == .platform { result.append(child) } else { visit(child) }
            }
        }
        visit(self)
        return result
    }

    var effectiveMatchKey: AnyHashable? {
        var node = parent
        while let current = node, current.kind == .group {
            if let key = current.matchKey { return key }
            node = current.parent
        }
        return nil
    }

    /// Frame in host coordinates (sum of platform ancestors' frames).
    var absoluteFrame: CGRect {
        var origin = frame.origin
        var current = platformAncestor
        while let node = current, node.kind == .platform {
            origin.x += node.frame.minX
            origin.y += node.frame.minY
            current = node.platformAncestor
        }
        return CGRect(origin: origin, size: frame.size)
    }

    /// Transition of the nearest `.transition` group between this node and its platform ancestor.
    var effectiveTransition: AnyTransition? {
        var node = parent
        while let current = node, current.kind == .group {
            if let transition = current.transition { return transition }
            node = current.parent
        }
        return nil
    }
}

/// The running animations of a node's frame and content, combined additively like SwiftUI's:
/// every animated change adds a layer that animates from the previous target to the new one,
/// and earlier layers keep running. The presented value is
/// `target − Σ (targetᵢ − targetᵢ₋₁)·(1 − progressᵢ)`, evaluated as an affine combination of the
/// targets (so content only needs interpolation). Retargeting on every mouse move therefore
/// keeps the motion's velocity instead of restarting from rest.
@MainActor
final class NodeAnimation {
    struct Layer {
        var frame: CGRect
        var content: RenderContent
        let animation: Animation
        let start: Double
    }

    private var baseFrame: CGRect
    private var baseContent: RenderContent
    private var layers: [Layer]
    var group: CompletionGroup?

    /// The newest layer's target (kept current by non-animated retargets).
    var toFrame: CGRect {
        get { layers[layers.count - 1].frame }
        set { layers[layers.count - 1].frame = newValue }
    }
    var toContent: RenderContent {
        get { layers[layers.count - 1].content }
        set { layers[layers.count - 1].content = newValue }
    }

    init(fromFrame: CGRect, fromContent: RenderContent, toFrame: CGRect, toContent: RenderContent, animation: Animation, start: Double, group: CompletionGroup?, previous: NodeAnimation? = nil) {
        let layer = Layer(frame: toFrame, content: toContent, animation: animation, start: start)
        if let previous {
            baseFrame = previous.baseFrame
            baseContent = previous.baseContent
            layers = previous.layers + [layer]
        } else {
            baseFrame = fromFrame
            baseContent = fromContent
            layers = [layer]
        }
        self.group = group
        // Bound rapid retargeting: the oldest (nearly settled) layers complete at once.
        while layers.count > 64 {
            baseFrame = layers[0].frame
            baseContent = layers[0].content
            layers.removeFirst()
        }
    }

    /// A non-animated change while animating applies at once: the frame shifts every layer by the
    /// change (so running motion continues around it), new content replaces all layers' content.
    func applyImmediately(frame: CGRect?, content: RenderContent?) {
        if let frame {
            let old = toFrame
            let dx = frame.minX - old.minX, dy = frame.minY - old.minY
            let dw = frame.width - old.width, dh = frame.height - old.height
            func shift(_ rect: inout CGRect) {
                rect.origin.x += dx; rect.origin.y += dy
                rect.size.width += dw; rect.size.height += dh
            }
            shift(&baseFrame)
            for index in layers.indices { shift(&layers[index].frame) }
        }
        if let content {
            // Parts recomputed every frame (Animatable paths, geometry-effect projections) take
            // the new value everywhere; the newest layer takes all of it.
            baseContent = Self.merging(content, into: baseContent)
            for index in layers.indices { layers[index].content = Self.merging(content, into: layers[index].content) }
            toContent = content
        }
    }

    private static func merging(_ new: RenderContent, into old: RenderContent) -> RenderContent {
        switch (old, new) {
        case let (.shape(previous), .shape(next)):
            var shape = previous
            shape.path = next.path
            shape.pathSize = next.pathSize
            return .shape(shape)
        case (.effect(.projection), .effect(.projection)):
            return new
        default:
            return old
        }
    }

    /// Samples the animation at `now`; finished oldest layers fold into the base.
    func value(at now: Double) -> (frame: CGRect, content: RenderContent, finished: Bool) {
        var progress = layers.map { $0.animation.sample(at: now - $0.start) }
        while let first = progress.first, first.finished {
            baseFrame = layers[0].frame
            baseContent = layers[0].content
            layers.removeFirst()
            progress.removeFirst()
            if layers.isEmpty { return (baseFrame, baseContent, true) }
        }
        // Affine weights of base, target₁ … targetₙ: (1 − p₁), (pₖ − pₖ₊₁), pₙ.
        let p = progress.map(\.progress)
        var weights = [1 - p[0]]
        for index in layers.indices {
            weights.append(index + 1 < layers.count ? p[index] - p[index + 1] : p[index])
        }
        var frame = baseFrame
        frame.origin.x *= weights[0]; frame.origin.y *= weights[0]
        frame.size.width *= weights[0]; frame.size.height *= weights[0]
        var content = baseContent
        var total = weights[0]
        for (index, layer) in layers.enumerated() {
            let w = weights[index + 1]
            frame.origin.x += layer.frame.origin.x * w
            frame.origin.y += layer.frame.origin.y * w
            frame.size.width += layer.frame.size.width * w
            frame.size.height += layer.frame.size.height * w
            let newTotal = total + w
            if abs(newTotal) > 1e-9 {
                content = RenderContent.interpolate(content, layer.content, w / newTotal)
            } else {
                content = layer.content
            }
            total = newTotal
        }
        return (frame, content, false)
    }
}

struct TransitionAnimation {
    var from: RenderPresentation
    var to: RenderPresentation
    var animation: Animation
    var start: Double
    var isRemoval: Bool
    var group: CompletionGroup?
}

/// Runs `withAnimation` completions when every animation started by the transaction ended.
@MainActor
final class CompletionGroup {
    var remaining = 0
    let completions: [@MainActor () -> Void]
    init(completions: [@MainActor () -> Void]) { self.completions = completions }

    func finishOne(_ run: (@escaping @MainActor () -> Void) -> Void) {
        remaining -= 1
        if remaining == 0 { for completion in completions { run(completion) } }
    }
}

/// Mirrors the render tree into a backend, batching changes per graph update. All platform
/// mutations happen in `commit()` (after the graph settled) or in `tick(at:)` (animations).
@MainActor
public final class Renderer {
    public let backend: any RenderBackend
    public let root: RenderNode
    unowned let tracer: UpdateTracer
    private var needsChildSync: [ObjectIdentifier: RenderNode] = [:]
    private var pending: [RenderNode] = []
    private var removed: [(node: RenderNode, container: RenderNode, transition: AnyTransition?, match: (key: AnyHashable, frame: CGRect)?)] = []
    private var matchedFrames: [AnyHashable: CGRect] = [:]
    private var ghosts: [ObjectIdentifier: (container: RenderNode, list: [(node: RenderNode, index: Int)])] = [:]
    private var animating: [ObjectIdentifier: RenderNode] = [:]

    /// Root transaction of the update being committed (nodes resolve their scope against it).
    var transaction = Transaction()
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    /// Deferred work (completions) is handed to the view graph.
    var schedule: (@escaping @MainActor () -> Void) -> Void = { $0() }
    private var completionGroup: CompletionGroup?

    init(backend: any RenderBackend, tracer: UpdateTracer) {
        self.backend = backend
        self.tracer = tracer
        self.root = RenderNode(kind: .root, path: nil)
        root.handle = backend.rootHandle
    }

    func makeGroup(path: ViewPath?) -> RenderNode { RenderNode(kind: .group, path: path) }
    func makePlatformNode(path: ViewPath?) -> RenderNode { RenderNode(kind: .platform, path: path) }

    func append(_ child: RenderNode, to parent: RenderNode) {
        child.parent = parent
        parent.children.append(child)
        structureChanged(below: parent)
    }

    func setChildren(of parent: RenderNode, _ children: [RenderNode]) {
        if parent.children.count == children.count, zip(parent.children, children).allSatisfy({ $0 === $1 }) { return }
        for child in children { child.parent = parent }
        parent.children = children
        structureChanged(below: parent)
    }

    func remove(_ node: RenderNode) {
        guard !node.isRemoved else { return }
        if node.kind == .platform, node.handle != nil, let container = node.platformAncestor {
            // Its index in the container is looked up at commit, only for a removal that animates.
            let match = node.effectiveMatchKey.map { (key: $0, frame: node.absoluteFrame) }
            removed.append((node, container, node.effectiveTransition, match))
        }
        node.isRemoved = true
        if node.kind == .platform { tracer.record(.renderRemove, node.path) }
        if let parent = node.parent {
            parent.children.removeAll { $0 === node }
            structureChanged(below: parent)
        }
        node.parent = nil
    }

    private func structureChanged(below node: RenderNode) {
        let target = node.kind == .group ? node.platformAncestor : node
        guard let target, !target.isRemoved else { return }
        needsChildSync[ObjectIdentifier(target)] = target
    }

    func update(_ node: RenderNode, frame: CGRect, content: RenderContent) {
        if node.targetFrame != frame {
            node.targetFrame = frame
            node.needsFrame = true
        }
        if node.targetContent != content {
            node.targetContent = content
            node.needsContent = true
        }
        if (node.needsFrame || node.needsContent) && !node.isPending {
            node.isPending = true
            pending.append(node)
        }
    }

    func setActions(_ node: RenderNode, _ actions: RenderActions) {
        node.actions = actions
    }

    func setAccessibility(_ node: RenderNode, _ properties: AccessibilityProperties) {
        node.accessibility = properties
        if let handle = node.handle { backend.updateAccessibility(of: handle, node: node) }
    }

    public var hasPendingChanges: Bool { !needsChildSync.isEmpty || !pending.isEmpty || !removed.isEmpty }
    public var hasActiveAnimations: Bool { !animating.isEmpty }

    private func animation(for node: RenderNode) -> Animation? {
        let resolved = node.animationScope?.resolve(transaction) ?? transaction
        return resolved.disablesAnimations ? nil : resolved.animation
    }

    private func groupForCommit() -> CompletionGroup? {
        if let completionGroup { return completionGroup }
        guard !transaction.completions.isEmpty else { return nil }
        let group = CompletionGroup(completions: transaction.completions)
        completionGroup = group
        return group
    }

    /// Applies all pending changes to the backend.
    public func commit() {
        let now = clock()
        completionGroup = nil

        // 0. Removals: top-level removed platform views may stay as "ghosts" while a removal
        //    transition runs.
        matchedFrames.removeAll()
        for record in removed where !record.container.isRemoved {
            if let match = record.match {
                // The matching inserted view will animate from here; drop this one immediately.
                matchedFrames[match.key] = match.frame
                continue
            }
            let transition = record.transition ?? .opacity
            let animation = transition.animation ?? self.animation(for: record.node)
            if let animation, let handle = record.node.handle {
                // The container's views still are the list before this commit.
                let synced = record.container.syncedChildren
                let index = synced.firstIndex { $0 === handle } ?? synced.count
                var entry = ghosts[ObjectIdentifier(record.container)] ?? (record.container, [])
                entry.list.append((record.node, index))
                ghosts[ObjectIdentifier(record.container)] = entry
                let group = groupForCommit()
                group?.remaining += 1
                record.node.transitionAnimation = TransitionAnimation(
                    from: record.node.presentation,
                    to: RenderPresentation(effect: transition.removal, size: record.node.frame.size),
                    animation: animation, start: now, isRemoval: true, group: group
                )
                animating[ObjectIdentifier(record.node)] = record.node
                needsChildSync[ObjectIdentifier(record.container)] = record.container
            }
        }
        removed.removeAll()

        // 1. Structure: create views for new platform nodes and sync child lists, top-down.
        var created: [ObjectIdentifier: Bool] = [:]
        while !needsChildSync.isEmpty {
            let batch = needsChildSync.values.sorted { depth(of: $0) < depth(of: $1) }
            needsChildSync.removeAll()
            for container in batch where !container.isRemoved {
                let children = container.platformChildren
                for child in children where child.handle == nil {
                    child.frame = child.targetFrame
                    child.content = child.targetContent
                    child.needsFrame = false
                    child.needsContent = false
                    child.handle = backend.makeView(for: child)
                    if child.accessibility != nil { backend.updateAccessibility(of: child.handle!, node: child) }
                    created[ObjectIdentifier(child)] = true
                    tracer.record(.renderInsert, child.path)
                    if !child.children.isEmpty { needsChildSync[ObjectIdentifier(child)] = child }
                    // Matched geometry: animate from the removed partner's frame.
                    if let key = child.effectiveMatchKey, let from = matchedFrames[key], let animation = animation(for: child) {
                        var origin = CGPoint.zero
                        var ancestor: RenderNode? = container
                        while let node = ancestor, node.kind == .platform {
                            origin.x += node.frame.minX
                            origin.y += node.frame.minY
                            ancestor = node.platformAncestor
                        }
                        let start = from.offsetBy(dx: -origin.x, dy: -origin.y)
                        let group = groupForCommit()
                        group?.remaining += 1
                        child.animation = NodeAnimation(fromFrame: start, fromContent: child.content, toFrame: child.targetFrame, toContent: child.targetContent, animation: animation, start: now, group: group)
                        child.frame = start
                        backend.setFrame(of: child.handle!, node: child)
                        animating[ObjectIdentifier(child)] = child
                        continue
                    }
                    // Insertion transition for views inserted into an existing container.
                    if created[ObjectIdentifier(container)] == nil {
                        let transition = child.effectiveTransition ?? .opacity
                        if let animation = transition.animation ?? animation(for: child) {
                            let active = RenderPresentation(effect: transition.insertion, size: child.frame.size)
                            if !active.isIdentity {
                                let group = groupForCommit()
                                group?.remaining += 1
                                child.presentation = active
                                backend.setPresentation(of: child.handle!, node: child)
                                child.transitionAnimation = TransitionAnimation(from: active, to: .identity, animation: animation, start: now, isRemoval: false, group: group)
                                animating[ObjectIdentifier(child)] = child
                            }
                        }
                    }
                }
                syncChildren(of: container, children)
            }
        }

        // 2. Property changes of existing views (animated when the change's transaction says so).
        let nodes = pending
        pending.removeAll(keepingCapacity: true)
        for node in nodes {
            node.isPending = false
            guard !node.isRemoved, let handle = node.handle else { continue }
            let frameChanged = node.needsFrame
            let contentChanged = node.needsContent
            node.needsFrame = false
            node.needsContent = false
            if contentChanged { tracer.record(.renderContent, node.path) }
            if frameChanged { tracer.record(.renderFrame, node.path) }
            if let animation = animation(for: node), created[ObjectIdentifier(node)] == nil {
                let group = groupForCommit()
                if node.animation?.group == nil { group?.remaining += 1 }
                // Earlier animations keep running (non-interpolable content simply takes the
                // newest value), so the frame keeps its motion.
                let interrupted = node.animation
                node.animation = NodeAnimation(fromFrame: node.frame, fromContent: node.content, toFrame: node.targetFrame, toContent: node.targetContent, animation: animation, start: now, group: group ?? interrupted?.group, previous: interrupted)
                animating[ObjectIdentifier(node)] = node
                if contentChanged, !RenderContent.canInterpolate(node.content, node.targetContent) {
                    node.content = node.targetContent
                    node.contentAnimation = animation
                    backend.updateContent(of: handle, node: node)
                    node.contentAnimation = nil
                }
            } else if let running = node.animation {
                // A non-animated change during a running animation (e.g. an Animatable view's
                // per-frame value) applies at once without cancelling the animation.
                running.applyImmediately(frame: frameChanged ? node.targetFrame : nil, content: contentChanged ? node.targetContent : nil)
                if contentChanged, !RenderContent.canInterpolate(node.content, node.targetContent) {
                    node.content = node.targetContent
                    backend.updateContent(of: handle, node: node)
                }
            } else {
                if contentChanged {
                    node.content = node.targetContent
                    backend.updateContent(of: handle, node: node)
                }
                if frameChanged {
                    node.frame = node.targetFrame
                    backend.setFrame(of: handle, node: node)
                }
            }
        }

        backend.didCommit()

        if let completionGroup, completionGroup.remaining == 0 {
            for completion in completionGroup.completions { schedule(completion) }
        } else if completionGroup == nil, !transaction.completions.isEmpty {
            for completion in transaction.completions { schedule(completion) }
        }
    }

    private func syncChildren(of container: RenderNode, _ children: [RenderNode]? = nil) {
        guard let handle = container.handle else { return }
        var list = children ?? container.platformChildren
        if let entry = ghosts[ObjectIdentifier(container)] {
            for ghost in entry.list.sorted(by: { $0.index < $1.index }) {
                list.insert(ghost.node, at: min(ghost.index, list.count))
            }
        }
        let handles = list.compactMap(\.handle)
        let old = container.syncedChildren
        container.syncedChildren = handles
        if old.isEmpty {
            if !handles.isEmpty {
                tracer.counters.childOperations += handles.count
                backend.setChildren(of: handle, node: container, to: handles)
            }
            return
        }
        // Only the range between the unchanged head and tail goes to the backend.
        var head = 0
        let common = min(old.count, handles.count)
        while head < common, old[head] === handles[head] { head += 1 }
        var tail = 0
        while tail < common - head, old[old.count - 1 - tail] === handles[handles.count - 1 - tail] { tail += 1 }
        let removed = head..<(old.count - tail)
        let inserted = Array(handles[head..<(handles.count - tail)])
        guard !removed.isEmpty || !inserted.isEmpty else { return }
        tracer.counters.childOperations += removed.count + inserted.count
        backend.replaceChildren(of: handle, node: container, range: removed, with: inserted, all: handles)
    }

    /// Advances running animations. Returns true while animations remain.
    @discardableResult
    public func tick(at now: Double) -> Bool {
        var resync: [ObjectIdentifier: RenderNode] = [:]
        for (key, node) in animating {
            guard let handle = node.handle else {
                animating[key] = nil
                continue
            }
            var active = false
            if let running = node.animation {
                let sample = running.value(at: now)
                if sample.finished {
                    node.animation = nil
                    node.frame = node.targetFrame
                    node.content = node.targetContent
                    running.group?.finishOne(schedule)
                } else {
                    node.frame = sample.frame
                    node.content = sample.content
                    active = true
                }
                backend.setFrame(of: handle, node: node)
                backend.updateContent(of: handle, node: node)
            }
            if let transition = node.transitionAnimation {
                let (progress, finished) = transition.animation.sample(at: now - transition.start)
                if finished {
                    node.transitionAnimation = nil
                    node.presentation = transition.isRemoval ? transition.to : .identity
                    transition.group?.finishOne(schedule)
                    if transition.isRemoval, let container = removeGhost(node) {
                        resync[ObjectIdentifier(container)] = container
                    }
                } else {
                    node.presentation = RenderPresentation.interpolate(transition.from, transition.to, progress)
                    active = true
                }
                backend.setPresentation(of: handle, node: node)
            }
            if !active { animating[key] = nil }
        }
        for container in resync.values where !container.isRemoved { syncChildren(of: container) }
        backend.didCommit()
        return !animating.isEmpty
    }

    private func removeGhost(_ node: RenderNode) -> RenderNode? {
        for (key, entry) in ghosts {
            if let index = entry.list.firstIndex(where: { $0.node === node }) {
                var updated = entry
                updated.list.remove(at: index)
                ghosts[key] = updated.list.isEmpty ? nil : updated
                return entry.container
            }
        }
        return nil
    }

    private func depth(of node: RenderNode) -> Int {
        var depth = 0
        var current = node.parent
        while let next = current {
            depth += 1
            current = next.parent
        }
        return depth
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: lerpValue(a.minX, b.minX, t), y: lerpValue(a.minY, b.minY, t),
               width: max(0, lerpValue(a.width, b.width, t)), height: max(0, lerpValue(a.height, b.height, t)))
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func lerpValue(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

// MARK: - Content interpolation

extension Color.Resolved {
    static func interpolate(_ a: Color.Resolved, _ b: Color.Resolved, _ t: Double) -> Color.Resolved {
        let f = Float(t)
        return Color.Resolved(red: a.red + (b.red - a.red) * f, green: a.green + (b.green - a.green) * f,
                              blue: a.blue + (b.blue - a.blue) * f, opacity: a.opacity + (b.opacity - a.opacity) * f)
    }
}

extension Path {
    /// Point-wise interpolation when both paths have the same structure; otherwise `b`.
    static func interpolate(_ a: Path, _ b: Path, _ t: Double) -> Path {
        guard a.elements.count == b.elements.count else { return b }
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: lerp(p.x, q.x, t), y: lerp(p.y, q.y, t)) }
        var result = Path()
        for (x, y) in zip(a.elements, b.elements) {
            switch (x, y) {
            case let (.move(p), .move(q)): result.move(to: mix(p, q))
            case let (.line(p), .line(q)): result.addLine(to: mix(p, q))
            case let (.quadCurve(p, c), .quadCurve(q, d)): result.addQuadCurve(to: mix(p, q), control: mix(c, d))
            case let (.curve(p, c1, c2), .curve(q, d1, d2)): result.addCurve(to: mix(p, q), control1: mix(c1, d1), control2: mix(c2, d2))
            case (.closeSubpath, .closeSubpath): result.closeSubpath()
            default: return b
            }
        }
        return result
    }
}

extension RenderContent {
    static func canInterpolate(_ a: RenderContent, _ b: RenderContent) -> Bool {
        switch (a, b) {
        case (.color, .color), (.shape, .shape): return true
        case let (.text(x), .text(y)): return x.string == y.string && x.font == y.font
        case let (.effect(x), .effect(y)):
            switch (x, y) {
            case (.opacity, .opacity), (.transform, .transform), (.clip, .clip), (.shadow, .shadow), (.projection, .projection): return true
            case let (.colorFilter(f0), .colorFilter(f1)): return ColorFilter.interpolate(f0, f1, 0) != nil
            default: return false
            }
        default: return false
        }
    }

    static func interpolate(_ a: RenderContent, _ b: RenderContent, _ t: Double) -> RenderContent {
        guard canInterpolate(a, b) else { return b }
        switch (a, b) {
        case let (.color(x), .color(y)):
            return .color(.interpolate(x, y, t))
        case let (.shape(x), .shape(y)):
            // The path follows the target (scaled to the animating frame by the backend, or driven
            // per frame by Animatable shapes); colors and line widths interpolate.
            var shape = y
            if let f0 = x.fill, let f1 = y.fill { shape.fill = .interpolate(f0, f1, t) }
            if let s0 = x.stroke, let s1 = y.stroke { shape.stroke = .interpolate(s0, s1, t) }
            if let g0 = x.gradient, let g1 = y.gradient { shape.gradient = .interpolate(g0, g1, t) }
            shape.lineWidth = lerp(x.lineWidth, y.lineWidth, t)
            return .shape(shape)
        case let (.text(x), .text(y)):
            var text = y
            text.color = .interpolate(x.color, y.color, t)
            return .text(text)
        case let (.effect(x), .effect(y)):
            switch (x, y) {
            case let (.opacity(o0), .opacity(o1)):
                return .effect(.opacity(o0 + (o1 - o0) * t))
            case let (.transform(off0, sc0, r0, a0), .transform(off1, sc1, r1, a1)):
                return .effect(.transform(
                    offset: CGSize(width: lerp(off0.width, off1.width, t), height: lerp(off0.height, off1.height, t)),
                    scale: CGSize(width: lerp(sc0.width, sc1.width, t), height: lerp(sc0.height, sc1.height, t)),
                    rotationDegrees: r0 + (r1 - r0) * t,
                    anchor: UnitPoint(x: lerp(a0.x, a1.x, t), y: lerp(a0.y, a1.y, t))))
            case let (.clip(p0), .clip(p1)):
                return .effect(.clip(.interpolate(p0, p1, t)))
            case let (.shadow(s0), .shadow(s1)):
                return .effect(.shadow(ResolvedShadow.interpolate(s0, s1, t)))
            case let (.colorFilter(f0), .colorFilter(f1)):
                return .effect(.colorFilter(ColorFilter.interpolate(f0, f1, t) ?? f1))
            case let (.projection(m0), .projection(m1)):
                var m = m1
                m.m11 = lerp(m0.m11, m1.m11, t); m.m12 = lerp(m0.m12, m1.m12, t); m.m13 = lerp(m0.m13, m1.m13, t)
                m.m21 = lerp(m0.m21, m1.m21, t); m.m22 = lerp(m0.m22, m1.m22, t); m.m23 = lerp(m0.m23, m1.m23, t)
                m.m31 = lerp(m0.m31, m1.m31, t); m.m32 = lerp(m0.m32, m1.m32, t); m.m33 = lerp(m0.m33, m1.m33, t)
                return .effect(.projection(m))
            default:
                return b
            }
        default:
            return b
        }
    }
}
