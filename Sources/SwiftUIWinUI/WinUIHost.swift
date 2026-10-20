#if os(Windows)
import Foundation
import CSwiftUIWinUI
import _SwiftUICore

/// Hosts one view graph in a C# `HostView` (one per window). Like the AppKit host, graph updates
/// are coalesced (one per main-loop turn, or synchronously at the end of an input event so the
/// next frame shows its effect), and animations are driven by `CompositionTarget.Rendering`.
@MainActor
final class WinUIHost {
    let view: sui_ref
    let backend: WinUIBackend
    private(set) var graph: ViewGraph!
    private var updateScheduled = false
    private var frameRequested = false
    private var insets = EdgeInsets()
    private var size = CGSize.zero
    /// The window's menu bar (the app's `.commands`).
    private(set) lazy var menuBar = WinUIMenuBar(host: self)

    init(view: sui_ref, makeGraph: (any RenderBackend) -> ViewGraph) {
        self.view = view
        backend = WinUIBackend(hostView: view, scale: 1)
        graph = makeGraph(backend)
        graph.setEnvironment { environment in
            // dismissWindow() closes this window.
            environment.dismissWindow = DismissWindowAction(_current: { [view] in sui_close_window(view) })
        }
        graph.clock = { WinUIPerf.now() }
        graph.onNeedsUpdate = { [weak self] in self?.scheduleUpdate() }
        graph.onNeedsAnimationFrame = { [weak self] in self?.requestFrame() }
        graph.onToolbarChange = { [weak self] toolbar in
            self?.updateToolbar(toolbar)
            self?.hidesTitle = toolbar.chrome.removesTitle
        }
        graph.onWindowConfigurationChange = { [weak self] configuration in
            guard let self else { return }
            toolbarBackgroundHidden = configuration.isToolbarBackgroundHidden == true
            let scheme = configuration.preferredColorScheme.map { $0 == .dark ? "dark" : "light" } ?? ""
            if scheme != windowColorScheme {
                windowColorScheme = scheme
                _ = WinUIPlatform.call(view, .setColorScheme, scheme)
            }
        }
        graph.onNavigationTitleChange = { [weak self] title in
            guard let self else { return }
            // nil: the scene's title.
            _ = WinUIPlatform.call(self.view, .setTitle, title)
        }
        menuBar.refresh()
    }

    /// Before the window opens: a hidden or plain title bar has no menu bar row (the Mac's menus are the
    /// app's, not the window's), and a content-sized window (`windowResizability(.contentSize)`, a utility
    /// window) opens at its content's ideal size, fixed when the content can't grow. Encoded "hidesMenuBar,
    /// width, height, fixed" (epx; -1: the host's default size).
    func configureWindow(_ description: WindowDescription) {
        let hidesMenuBar = description.kind == .hiddenTitleBar || description.kind == .plain
        hiddenTitleBar = description.kind == .hiddenTitleBar
        var size = CGSize(width: -1, height: -1)
        var fixed = false
        if description.defaultSize == nil, description.kind == .utility || description.resizability == .contentSize {
            let ideal = graph.sizeThatFits(.unspecified)
            let maximum = graph.sizeThatFits(ProposedViewSize(width: .infinity, height: .infinity))
            size = CGSize(width: ideal.width.rounded(.up), height: ideal.height.rounded(.up))
            fixed = description.resizability == .contentSize && maximum.width <= ideal.width + 0.5
                && maximum.height <= ideal.height + 0.5
        }
        let fields = [hidesMenuBar ? "1" : "0", "\(Float(size.width))", "\(Float(size.height))", fixed ? "1" : "0"]
        _ = WinUIPlatform.call(view, .configureWindow, fields.joined(separator: ","))
    }

    // MARK: Title bar

    /// The content runs up into the title bar row, as on the Mac: a hidden title bar, or the window toolbar's background
    /// hidden (`toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`), where the content draws its own bar.
    private var hiddenTitleBar = false { didSet { updateTitleBar() } }
    private var toolbarBackgroundHidden = false { didSet { updateTitleBar() } }
    /// `toolbar(removing: .title)`: the row shows no window title.
    private var hidesTitle = false { didSet { updateTitleBar() } }
    private var titleBarDescription = ""
    /// The appearance asked of the window ("dark", "light", "": the system's).
    private var windowColorScheme = ""
    /// The row as the host lays it out (epx), for `windowTitleBarArea`.
    private var titleBarArea = WindowTitleBarArea(height: 0, leading: 0, trailing: 0)

    private func updateTitleBar() {
        let contentInTitleBar = hiddenTitleBar || toolbarBackgroundHidden
        let description = (contentInTitleBar ? "1" : "0") + "," + (hidesTitle ? "1" : "0")
        guard description != titleBarDescription else { return }
        titleBarDescription = description
        _ = WinUIPlatform.call(view, .setTitleBar, description)
        let area = contentInTitleBar ? titleBarArea : nil
        graph.setEnvironment { $0.windowTitleBarArea = area }
    }

    private var tornDown = false

    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
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
        WinUIPerf.measure(.update) { graph.update() }
        backend.flush()
        // Commands read app state: re-evaluate them after each update (sent only when changed).
        menuBar.refresh()
    }

    func setSize(_ size: CGSize, scale: CGFloat) {
        guard size != self.size || scale != backend.scale else { return }
        self.size = size
        backend.scale = scale
        graph.setProposedSize(ProposedViewSize(size))
        WinUIPerf.measure(.update) { graph.update() }
        backend.flush()
    }

    func setEnvironment(key: Int32, value: Int32) {
        switch key {
        case 1:
            let scheme: ColorScheme = value == 1 ? .dark : .light
            graph.setEnvironment { $0.colorScheme = scheme }
            AppRuntime.environment.colorScheme = scheme
        case 2, 3, 4:
            // The title bar row (epx): its height, the menu bar's reach from the leading edge, the caption buttons'
            // (and the toolbar's) from the trailing one.
            let points = CGFloat(value)
            switch key {
            case 2: titleBarArea.height = points
            case 3: titleBarArea.leading = points
            default: titleBarArea.trailing = points
            }
            if titleBarDescription.hasPrefix("1") {
                let area = titleBarArea
                graph.setEnvironment { $0.windowTitleBarArea = area }
            }
        default:
            break
        }
        flushNow()
    }

    func flushNow() {
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
        WinUIPerf.measure(.frame) { graph.renderAnimationFrame() }
        backend.flush()
        if graph.hasActiveAnimations { requestFrame() }
    }

    // MARK: Events

    enum Event: Int32 {
        case primary = 1, setBool, setText, setDouble, editingChanged, pressed, submit = 8, focusChanged, secondaryClick
        case scrolled, scrollPhase, openURL, setDate, setColor, setSelection
        case pointerBegan = 20, pointerMoved, pointerEnded, pointerCancelled
        case hover = 24, hoverLocation
        /// Host-level events (node -1): a menu bar item (text = its id) and a finished file
        /// dialog (a = request id, c = 1 if confirmed, text = chosen paths, one per line).
        case menuItem = 30, fileDialog
    }

    func handle(node id: Int32, type: Int32, a: Double, b: Double, c: Double, text: String?) {
        if id == -1 {
            switch Event(rawValue: type) {
            case .menuItem: if let text { menuBar.perform(id: text) }
            case .fileDialog: backend.fileDialogs.complete(id: Int(a), paths: c != 0 ? (text ?? "").split(separator: "\n").map(String.init) : nil)
            default: if let text { toolbarAction(text) }
            }
            flushNow()
            return
        }
        guard let event = Event(rawValue: type), let node = backend.node(for: id) else { return }
        let actions = node.actions
        switch event {
        case .primary: actions.primary?()
        case .menuItem, .fileDialog: break // host-level (node -1)
        case .setBool: actions.setBool?(a != 0)
        case .setText: actions.setText?(text ?? "")
        case .setSelection: actions.setSelection?(Int(a)..<(Int(a) + Int(b)))
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

    /// Escape / the title bar's Back button: dismisses the top presentation (sheet, alert, ...),
    /// else pops the navigation stack.
    func back() -> Bool {
        var handled = graph.dismissTopPresentation()
        if !handled, let pop = toolbarActions["navigation.back"] {
            pop()
            handled = true
        }
        flushNow()
        return handled
    }

    // MARK: Toolbar (the window's command bar)

    private var toolbarActions: [String: @MainActor () -> Void] = [:]
    private var toolbarDescription = ""

    /// Toolbar buttons become command bar buttons (the back button the title bar's Back). Encoded
    /// one entry per line: id, placement, title, glyph, enabled, filled (fields separated by U+001F).
    private func updateToolbar(_ toolbar: WindowToolbar) {
        var actions: [String: @MainActor () -> Void] = [:]
        var lines: [String] = []
        for entry in toolbar.items {
            guard let button = entry.button else {
                if entry.search == nil { WinUILog.warning("Toolbar item \(entry.id): only buttons are shown in the WinUI command bar yet") }
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
        _ = WinUIPlatform.call(view, .setToolbar, description)
    }

    func toolbarAction(_ id: String) {
        toolbarActions[id]?()
        flushNow()
    }
}

/// Foundation run loop timers on Windows: nobody runs `RunLoop.main` (the host owns the message
/// loop), so due timers are fired here and the host arms a `DispatcherQueueTimer` for the next one.
@MainActor
enum WinUIMainLoop {
    /// After a callback that may have scheduled timers: fires due ones and re-arms, soon, from the
    /// host's timer. Not here: on Windows, Foundation's main run loop also dispatches window messages
    /// (it's set to receive all input), and doing that inside a XAML callback (an event, a frame, a
    /// dispatcher item) re-enters XAML's dispatcher, which fail-fasts or stops dispatching for good.
    static func serviceTimers() {
        sui_main_loop_arm_timer(0)
    }

    /// The host's timer fired: a Win32 thread timer the message loop dispatches at the top level, outside
    /// XAML's dispatch.
    static func fireTimers() {
        guard let next = RunLoop.main.limitDate(forMode: .default) else {
            sui_main_loop_arm_timer(-1)
            return
        }
        let delay = next.timeIntervalSinceNow
        sui_main_loop_arm_timer(delay > 86_400 ? -1 : max(0, delay))
    }
}
#endif
