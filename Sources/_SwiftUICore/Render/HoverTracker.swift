import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Hover for every backend, like a browser's: the views under the pointer are found only once the
/// pointer has rested and nothing has scrolled for `restDelay` (or at once on a click), against the
/// renderer's index of hover regions, never by walking the views. While content scrolls under a
/// resting pointer nothing is hit-tested at all (a platform's tracking areas would test every view on
/// every frame); views already hovered get the pointer's location as it moves and leave as soon as
/// it leaves them.
///
/// Hosts report the pointer in root coordinates (`pointerMoved`, `pointerPressed`, `pointerExited`)
/// and run `wake()` when the delay they were asked for (`requestWakeUp`) has passed.
@MainActor
public final class HoverTracker {
    /// How long the pointer must rest, and scrolling stop, before hover is hit-tested.
    public static let restDelay = 0.1

    unowned let renderer: Renderer
    unowned let tracer: UpdateTracer
    var clock: () -> Double
    /// Asks the host to call `wake()` after a delay (seconds). Hosts without timers can leave it nil
    /// and call `wake()` themselves.
    public var requestWakeUp: ((Double) -> Void)?

    /// The pointer in root coordinates; nil while it is outside the host.
    public private(set) var pointer: CGPoint?
    private var lastActivity = -Double.infinity
    private var wakeScheduled = false
    private var hovered: [RenderNode] = []

    init(renderer: Renderer, tracer: UpdateTracer, clock: @escaping () -> Double) {
        self.renderer = renderer
        self.tracer = tracer
        self.clock = clock
    }

    /// Views currently hovered (outermost first, as hit-tested).
    public var hoveredNodes: [RenderNode] { hovered }

    // MARK: Events

    /// The pointer moved inside the host (root coordinates).
    public func pointerMoved(to point: CGPoint) {
        guard point != pointer else { return }
        pointer = point
        lastActivity = clock()
        // Hovered views follow the pointer and leave as it leaves them; entering waits for a rest.
        var kept: [RenderNode] = []
        for node in hovered {
            if let local = localPoint(point, in: node) {
                kept.append(node)
                node.actions.hoverLocation?(local)
            } else {
                exit(node)
            }
        }
        hovered = kept
        scheduleWake()
    }

    /// A click: hover is hit-tested at once, before the click is handled.
    public func pointerPressed(at point: CGPoint) {
        pointer = point
        hitTest()
    }

    /// The pointer left the host.
    public func pointerExited() {
        pointer = nil
        for node in hovered { exit(node) }
        hovered = []
    }

    /// A scroll view moved its content: what is under the pointer is tested once scrolling rests.
    public func contentScrolled() {
        lastActivity = clock()
        if pointer != nil { scheduleWake() }
    }

    /// Views moved or appeared without a scroll (a commit): tested at the next rest.
    func contentChanged() {
        if pointer != nil, !hovered.isEmpty || renderer.hasHoverRegions { scheduleWake() }
    }

    /// The delay the host was asked for has passed.
    public func wake() {
        wakeScheduled = false
        guard pointer != nil else { return }
        let idle = clock() - lastActivity
        if idle + 1e-9 >= Self.restDelay {
            hitTest()
        } else {
            wakeScheduled = true
            requestWakeUp?(Self.restDelay - idle)
        }
    }

    private func scheduleWake() {
        guard !wakeScheduled else { return }
        wakeScheduled = true
        requestWakeUp?(Self.restDelay)
    }

    // MARK: Hit testing

    /// Finds the hover regions under the pointer (every one containing it, like tracking areas) and
    /// tells the views that entered and left.
    func hitTest() {
        guard let point = pointer else { return }
        var found: [RenderNode] = []
        for node in renderer.hoverRegions {
            tracer.counters.hitTestVisits += 1
            if localPoint(point, in: node) != nil { found.append(node) }
        }
        let now = Set(found.map(ObjectIdentifier.init))
        let before = Set(hovered.map(ObjectIdentifier.init))
        for node in hovered where !now.contains(ObjectIdentifier(node)) { exit(node) }
        for node in found {
            guard let local = localPoint(point, in: node) else { continue }
            if !before.contains(ObjectIdentifier(node)) { node.actions.hover?(true) }
            node.actions.hoverLocation?(local)
        }
        hovered = found
    }

    private func exit(_ node: RenderNode) {
        node.actions.hover?(false)
        node.actions.hoverLocation?(nil)
    }

    /// The point in the node's own coordinates when it lies inside the node and inside the scroll
    /// views around it (their offsets applied); nil otherwise.
    private func localPoint(_ point: CGPoint, in node: RenderNode) -> CGPoint? {
        guard !node.isRemoved, node.handle != nil else { return nil }
        // The node's origin in root coordinates: platform ancestors' origins, minus scroll offsets.
        var origin = node.frame.origin
        var current = node.platformAncestor
        var inScrollView = false
        while let ancestor = current, ancestor.kind == .platform {
            if case .scrollView = ancestor.content {
                origin.x -= ancestor.contentOffset.x
                origin.y -= ancestor.contentOffset.y
                inScrollView = true
            }
            origin.x += ancestor.frame.minX
            origin.y += ancestor.frame.minY
            current = ancestor.platformAncestor
        }
        guard CGRect(origin: origin, size: node.frame.size).contains(point) else { return nil }
        if inScrollView, !scrollClipsContain(point, node: node) { return nil }
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// Whether the point lies inside every scroll view around the node (their visible bounds).
    private func scrollClipsContain(_ point: CGPoint, node: RenderNode) -> Bool {
        var current = node.platformAncestor
        while let ancestor = current, ancestor.kind == .platform {
            if case .scrollView = ancestor.content {
                // The scroll view's frame in root coordinates.
                var origin = ancestor.frame.origin
                var outer = ancestor.platformAncestor
                while let next = outer, next.kind == .platform {
                    if case .scrollView = next.content {
                        origin.x -= next.contentOffset.x
                        origin.y -= next.contentOffset.y
                    }
                    origin.x += next.frame.minX
                    origin.y += next.frame.minY
                    outer = next.platformAncestor
                }
                if !CGRect(origin: origin, size: ancestor.frame.size).contains(point) { return false }
            }
            current = ancestor.platformAncestor
        }
        return true
    }
}
