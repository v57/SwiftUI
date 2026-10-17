import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import _SwiftUICore

/// Hosts a view on the headless backend. Updates are explicit (`flush()`), which makes update
/// counts deterministic for tests and parity runs.
@MainActor
public final class TestHost {
    public let backend = HeadlessBackend()
    public let graph: ViewGraph
    public private(set) var needsFlush = false
    /// Manual animation clock (seconds).
    public private(set) var time: Double = 0

    public init<Root: View>(_ root: Root, size: CGSize = CGSize(width: 400, height: 600)) {
        let clock = ManualClock()
        self.clock = clock
        graph = ViewGraph(rootView: root, backend: backend, proposedSize: ProposedViewSize(size))
        graph.clock = { clock.time }
        graph.onNeedsUpdate = { [weak self] in self?.needsFlush = true }
        graph.onToolbarChange = { [weak self] in self?.showToolbar($0) }
        installHoverWakeUps()
        flush()
    }

    /// Hosts a graph built by a factory (e.g. a scene's `makeGraphForValue`).
    public init(size: CGSize = CGSize(width: 400, height: 600), graph makeGraph: (any RenderBackend) -> ViewGraph) {
        let clock = ManualClock()
        self.clock = clock
        graph = makeGraph(backend)
        graph.setProposedSize(ProposedViewSize(size))
        graph.clock = { clock.time }
        graph.onNeedsUpdate = { [weak self] in self?.needsFlush = true }
        graph.onToolbarChange = { [weak self] in self?.showToolbar($0) }
        installHoverWakeUps()
        flush()
    }

    // MARK: Pointer (hover)

    /// When the hover tracker asked to be woken (manual clock time).
    public private(set) var hoverWakeUp: Double?

    private func installHoverWakeUps() {
        graph.hoverTracker.requestWakeUp = { [weak self] delay in
            guard let self else { return }
            let due = self.clock.time + delay
            self.hoverWakeUp = min(self.hoverWakeUp ?? due, due)
        }
    }

    /// Wakes the hover tracker when its delay passed (like the host's timer firing), then updates.
    private func fireHoverWakeUp() {
        guard let due = hoverWakeUp, clock.time + 1e-9 >= due else { return }
        hoverWakeUp = nil
        graph.hoverTracker.wake()
        flush()
    }

    /// Moves the pointer to a point in root coordinates (a mouse-moved event).
    public func movePointer(to point: CGPoint) {
        graph.hoverTracker.pointerMoved(to: point)
        flush()
    }

    /// Clicks at a point: hover is hit-tested at once (the click itself is not delivered).
    public func pressPointer(at point: CGPoint) {
        graph.hoverTracker.pointerPressed(at: point)
        flush()
    }

    public func pointerExited() {
        graph.hoverTracker.pointerExited()
        flush()
    }

    /// Advances the clock in small steps without animation frames being required (lets the hover
    /// tracker's wake-ups fire).
    public func wait(_ seconds: Double) {
        var remaining = seconds
        while remaining > 1e-9 {
            let step = min(remaining, 1.0 / 120)
            advance(by: step)
            remaining -= step
        }
    }

    // MARK: Window toolbar

    /// The window toolbar's items, hosted in their own graph like a window's toolbar views.
    public let toolbarBackend = HeadlessBackend()
    public private(set) var toolbarGraph: ViewGraph?

    private func showToolbar(_ toolbar: WindowToolbar) {
        let root = _HeadlessToolbar(entries: toolbar.items)
        if let toolbarGraph {
            toolbarGraph.setRootView(root)
        } else {
            let toolbarGraph = ViewGraph(rootView: root, backend: toolbarBackend, proposedSize: ProposedViewSize(CGSize(width: 800, height: 52)))
            toolbarGraph.clock = graph.clock
            toolbarGraph.onNeedsUpdate = { [weak self] in self?.needsFlush = true }
            self.toolbarGraph = toolbarGraph
        }
    }

    private let clock: ManualClock

    /// Advances the animation clock and renders one animation frame.
    public func advance(by seconds: Double) {
        clock.time += seconds
        time = clock.time
        graph.renderAnimationFrame()
        toolbarGraph?.renderAnimationFrame()
        fireHoverWakeUp()
    }

    /// Runs animation frames at 60 Hz until all animations finished (or `limit` seconds passed).
    public func finishAnimations(limit: Double = 10) {
        var elapsed = 0.0
        while (graph.hasActiveAnimations || toolbarGraph?.hasActiveAnimations == true) && elapsed < limit {
            advance(by: 1.0 / 60)
            elapsed += 1.0 / 60
        }
    }

    public var tracer: UpdateTracer { graph.tracer }
    public var root: HeadlessView { backend.root }

    /// Runs one update transaction (like one run-loop turn in an app).
    public func flush() {
        needsFlush = false
        graph.update()
        // Toolbar edits feed back into the window's graph (bindings), and toolbar items change
        // after window updates.
        for _ in 0..<4 {
            guard let toolbarGraph, toolbarGraph.needsUpdate || graph.needsUpdate else { break }
            toolbarGraph.update()
            graph.update()
        }
    }

    public func resize(to size: CGSize) {
        graph.setProposedSize(ProposedViewSize(size))
        flush()
    }

    /// Clears recorded update events.
    public func resetTrace() { tracer.reset() }

    // MARK: Queries

    /// Views of the window content followed by those of the toolbar.
    public var allViews: [HeadlessView] { root.allDescendants + (toolbarGraph == nil ? [] : toolbarBackend.root.allDescendants) }

    public func views(withText text: String) -> [HeadlessView] { allViews.filter { $0.text == text } }

    public func view(withText text: String) -> HeadlessView? { views(withText: text).first }

    public var texts: [String] { allViews.compactMap(\.text) }

    public func dump() -> String { root.description }

    // MARK: Interaction (runs the handler, then flushes like an event + run loop turn would)

    /// Taps the innermost button or tap target containing a text view with `text`.
    public func tap(_ text: String) {
        guard let label = view(withText: text) else { fatalError("No view with text \(text)\n\(dump())") }
        var current: HeadlessView? = label
        while let view = current {
            if let action = view.node?.actions.primary {
                view.node?.actions.pressed?(true)
                view.node?.actions.pressed?(false)
                action()
                flush()
                return
            }
            if let pointer = view.node?.actions.pointer {
                let center = CGPoint(x: view.frame.width / 2, y: view.frame.height / 2)
                pointer(PointerEvent(phase: .began, location: center, timestamp: time))
                pointer(PointerEvent(phase: .ended, location: center, timestamp: time + 0.05))
                flush()
                return
            }
            current = view.superview
        }
        fatalError("No tappable ancestor for \(text)")
    }

    /// Drags starting on the view showing `text` by `translation` (in `steps` moves).
    public func drag(_ text: String, by translation: CGSize, steps: Int = 5) {
        guard let label = view(withText: text) else { fatalError("No view with text \(text)") }
        var current: HeadlessView? = label
        while let view = current, view.node?.actions.pointer == nil { current = view.superview }
        guard let target = current, let pointer = target.node?.actions.pointer else { fatalError("No gesture target for \(text)") }
        let start = CGPoint(x: target.frame.width / 2, y: target.frame.height / 2)
        pointer(PointerEvent(phase: .began, location: start, timestamp: time))
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            pointer(PointerEvent(phase: .moved, location: CGPoint(x: start.x + translation.width * fraction, y: start.y + translation.height * fraction), timestamp: time + Double(step) * 0.016))
            flush()
        }
        pointer(PointerEvent(phase: .ended, location: CGPoint(x: start.x + translation.width, y: start.y + translation.height), timestamp: time + Double(steps + 1) * 0.016))
        flush()
    }

    /// Right-clicks (context menu) the view showing `text`.
    public func secondaryClick(_ text: String) {
        guard let label = view(withText: text) else { fatalError("No view with text \(text)") }
        var current: HeadlessView? = label
        while let view = current {
            if let action = view.node?.actions.secondaryClick {
                action()
                flush()
                return
            }
            current = view.superview
        }
        fatalError("No context menu for \(text)")
    }

    /// Scrolls the `index`th scroll view to a content offset (like a user scroll).
    public func scroll(to offset: CGPoint, scrollViewAt index: Int = 0) {
        let scrollViews = allViews.filter { if case .scrollView = $0.content { return true } else { return false } }
        scrollViews[index].contentOffset = offset
        scrollViews[index].node?.actions.scrolled?(offset)
        flush()
    }

    /// Scrolls the `index`th scroll view by `delta` per frame for `frames` frames at 120 Hz, like a
    /// trackpad scroll (the clock advances, so hover wake-ups may come due meanwhile).
    public func scroll(by delta: CGPoint, frames: Int, scrollViewAt index: Int = 0) {
        let scrollViews = allViews.filter { if case .scrollView = $0.content { return true } else { return false } }
        let view = scrollViews[index]
        guard let node = view.node else { return }
        for _ in 0..<frames {
            let offset = view.contentOffset
            view.contentOffset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
            node.actions.scrolled?(view.contentOffset)
            flush()
            advance(by: 1.0 / 120)
        }
    }

    /// Escape key: dismisses the top presentation.
    public func pressEscape() {
        graph.dismissTopPresentation()
        flush()
    }

    public func setToggle(at index: Int = 0, to value: Bool) {
        let toggles = allViews.filter { if case .toggle = $0.content { return true } else { return false } }
        toggles[index].node?.actions.setBool?(value)
        flush()
    }

    public func type(_ text: String, intoFieldAt index: Int = 0) {
        let fields = allViews.filter { if case .textField = $0.content { return true } else { return false } }
        fields[index].node?.actions.setText?(text)
        flush()
    }
}

/// Toolbar items side by side, each with the environment of its `.toolbar` site.
struct _HeadlessToolbar: View {
    let entries: [ToolbarEntry]
    var body: some View {
        HStack {
            ForEach(entries.indices, id: \.self) { index in
                entries[index].content.environment(\.self, entries[index].environment)
            }
        }
    }
}

@MainActor
final class ManualClock {
    var time: Double = 0
}
