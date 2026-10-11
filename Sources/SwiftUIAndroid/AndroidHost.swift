#if os(Android)
import Foundation
import CSwiftUIAndroid
import _SwiftUICore

/// Hosts one view graph in an `dev.v57.swiftui.HostView`. Like the AppKit host, graph updates are
/// coalesced (one per main-loop turn, or synchronously at the end of an input event so the next
/// frame shows its effect), and animations are driven by Choreographer frame callbacks.
@MainActor
final class AndroidHost {
    let view: sui_ref
    let backend: AndroidBackend
    private(set) var graph: ViewGraph!
    private var updateScheduled = false
    private var frameRequested = false
    private var insets = EdgeInsets()
    private var size = CGSize.zero

    init(view: sui_ref, density: CGFloat, makeGraph: (any RenderBackend) -> ViewGraph) {
        self.view = view
        backend = AndroidBackend(hostView: view, density: density)
        graph = makeGraph(backend)
        graph.clock = { AndroidPerf.now() }
        graph.onNeedsUpdate = { [weak self] in self?.scheduleUpdate() }
        graph.onNeedsAnimationFrame = { [weak self] in self?.requestFrame() }
        graph.onToolbarChange = { [weak self] toolbar in self?.updateToolbar(toolbar) }
        graph.onNavigationTitleChange = { [weak self] title in
            guard let self else { return }
            // nil: the activity's own label.
            _ = AndroidPlatform.call(self.view, .setTitle, title)
        }
    }

    func tearDown() {
        graph.tearDown()
        backend.flush()
        sui_delete_global_ref(view)
    }

    // MARK: Updates

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    /// Runs a pending graph update now.
    func flush() {
        guard updateScheduled || graph.needsUpdate else { return }
        updateScheduled = false
        AndroidPerf.measure(.update) { graph.update() }
        backend.flush()
    }

    func setSize(_ size: CGSize) {
        guard size != self.size else { return }
        self.size = size
        graph.setProposedSize(ProposedViewSize(size))
        AndroidPerf.measure(.update) { graph.update() }
        backend.flush()
    }

    func setEnvironment(key: Int32, value: Int32) {
        switch key {
        case 1:
            let scheme: ColorScheme = value == 1 ? .dark : .light
            graph.setEnvironment { $0.colorScheme = scheme }
        default:
            break
        }
        flushNow()
    }

    private func flushNow() {
        updateScheduled = true
        flush()
    }

    // MARK: Animation frames

    private func requestFrame() {
        guard !frameRequested else { return }
        frameRequested = true
        sui_host_request_frame(view)
    }

    func frame() {
        frameRequested = false
        AndroidPerf.measure(.frame) { graph.renderAnimationFrame() }
        backend.flush()
        if graph.hasActiveAnimations { requestFrame() }
    }

    // MARK: Events

    enum Event: Int32 {
        case primary = 1, setBool, setText, setDouble, editingChanged, pressed, submit = 8, focusChanged, secondaryClick
        case scrolled, scrollPhase, openURL, setDate, setColor
        case pointerBegan = 20, pointerMoved, pointerEnded, pointerCancelled
        case hover = 24, hoverLocation
    }

    func handle(node id: Int32, type: Int32, a: Double, b: Double, c: Double, text: String?) {
        if id == -1, let text {
            toolbarAction(text)
            return
        }
        guard let event = Event(rawValue: type), let node = backend.node(for: id) else { return }
        let actions = node.actions
        switch event {
        case .primary: actions.primary?()
        case .setBool: actions.setBool?(a != 0)
        case .setText: actions.setText?(text ?? "")
        case .setDouble: actions.setDouble?(a)
        case .editingChanged: actions.editingChanged?(a != 0)
        case .pressed: actions.pressed?(a != 0)
        case .submit: actions.submit?()
        case .focusChanged: actions.focusChanged?(a != 0)
        case .secondaryClick: actions.secondaryClick?()
        case .scrolled: actions.scrolled?(CGPoint(x: a, y: b))
        case .scrollPhase:
            let phases: [ScrollPhase] = [.idle, .tracking, .interacting, .decelerating, .animating]
            actions.scrollPhase?(phases[max(0, min(phases.count - 1, Int(a)))])
        case .openURL:
            guard let text, let url = URL(string: text) else { break }
            if let open = actions.openURL { open(url) } else { backend.openURL(url) }
        case .setDate: actions.setDate?(Date(timeIntervalSince1970: a))
        case .setColor:
            let argb = UInt32(truncatingIfNeeded: Int64(a))
            func channel(_ shift: UInt32) -> Float { Float((argb >> shift) & 0xFF) / 255 }
            actions.setColor?(Color.Resolved(red: channel(16), green: channel(8), blue: channel(0), opacity: channel(24)))
        case .hover:
            actions.hover?(a != 0)
        case .hoverLocation:
            actions.hoverLocation?(c != 0 ? CGPoint(x: a, y: b) : nil)
        case .pointerBegan, .pointerMoved, .pointerEnded, .pointerCancelled:
            let phase: PointerEvent.Phase = event == .pointerBegan ? .began : event == .pointerMoved ? .moved : event == .pointerEnded ? .ended : .cancelled
            actions.pointer?(PointerEvent(phase: phase, location: CGPoint(x: a, y: b), timestamp: c))
        }
        // Show the event's effect in the next frame.
        flush()
    }

    /// The system Back button: dismisses the top presentation (sheet, alert, ...), else pops the
    /// navigation stack.
    func back() -> Bool {
        var handled = graph.dismissTopPresentation()
        if !handled, let pop = toolbarActions["navigation.back"] {
            pop()
            handled = true
        }
        flushNow()
        return handled
    }

    // MARK: Toolbar (the activity's app bar)

    private var toolbarActions: [String: @MainActor () -> Void] = [:]
    private var toolbarDescription = ""

    /// Toolbar buttons become app bar actions (the back button its Up arrow). Encoded one entry
    /// per line: id, placement, title, glyph, enabled (fields separated by U+001F).
    private func updateToolbar(_ toolbar: WindowToolbar) {
        var actions: [String: @MainActor () -> Void] = [:]
        var lines: [String] = []
        for entry in toolbar.items {
            guard let button = entry.button else {
                if entry.search == nil { AndroidLog.warning("Toolbar item \(entry.id): only buttons are shown in the Android app bar yet") }
                continue
            }
            actions[entry.id] = button.action
            let glyph = button.systemImage.map { SymbolFont.glyph(forSystemName: $0) }
            let fields = [entry.id, "\(entry.placement)", button.title ?? button.help ?? "", glyph?.text ?? "", button.isEnabled ? "1" : "0", glyph?.filled == true ? "1" : "0"]
            lines.append(fields.joined(separator: "\u{1F}"))
        }
        toolbarActions = actions
        let description = lines.joined(separator: "\n")
        guard description != toolbarDescription else { return }
        toolbarDescription = description
        _ = AndroidPlatform.call(view, .setToolbar, description)
    }

    func toolbarAction(_ id: String) {
        toolbarActions[id]?()
        flushNow()
    }
}

/// Foundation run loop timers on Android: nobody runs `RunLoop.main`, so the host fires due
/// timers itself and arms a timerfd on the main looper for the next one.
@MainActor
enum AndroidMainLoop {
    static func serviceTimers() {
        guard let next = RunLoop.main.limitDate(forMode: .default) else {
            sui_main_loop_arm_timer(-1)
            return
        }
        let delay = next.timeIntervalSinceNow
        sui_main_loop_arm_timer(delay > 86_400 ? -1 : max(0, delay))
    }
}
#endif
