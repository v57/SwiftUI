import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import SwiftUI2Core

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
        flush()
    }

    private let clock: ManualClock

    /// Advances the animation clock and renders one animation frame.
    public func advance(by seconds: Double) {
        clock.time += seconds
        time = clock.time
        graph.renderAnimationFrame()
    }

    /// Runs animation frames at 60 Hz until all animations finished (or `limit` seconds passed).
    public func finishAnimations(limit: Double = 10) {
        var elapsed = 0.0
        while graph.hasActiveAnimations && elapsed < limit {
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
    }

    public func resize(to size: CGSize) {
        graph.setProposedSize(ProposedViewSize(size))
        flush()
    }

    /// Clears recorded update events.
    public func resetTrace() { tracer.reset() }

    // MARK: Queries

    public var allViews: [HeadlessView] { root.allDescendants }

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
        scrollViews[index].node?.actions.scrolled?(offset)
        flush()
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

@MainActor
final class ManualClock {
    var time: Double = 0
}
