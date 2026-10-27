#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Hosts one view graph in a GTK widget: a `GtkDrawingArea` the render tree is painted into,
/// under a `GtkFixed` layer for native widgets (text being edited). Like the AppKit host, graph
/// updates are coalesced (one per main-loop turn, from a high-priority idle before GTK redraws)
/// and animations run on the widget's frame clock.
@MainActor
public final class GtkHost {
    public let backend = GtkBackend()
    public private(set) var graph: ViewGraph!
    /// The host's widget (add it to a window or container).
    public let widget: UnsafeMutablePointer<GtkWidget>
    let drawingArea: UnsafeMutablePointer<GtkWidget>
    let fixed: UnsafeMutablePointer<GtkWidget>
    /// The toplevel window (for dialogs).
    var window: UnsafeMutablePointer<GtkWidget>? {
        let toplevel = gtk_widget_get_toplevel(widget)
        return toplevel.flatMap { gtk_widget_is_toplevel($0) != 0 ? $0 : nil }
    }

    private(set) var size = CGSize.zero
    private var idleSource: guint = 0
    private var tickID: guint = 0
    private var isTornDown = false
    /// Paints the theme's window background under the content.
    var drawsBackground = true
    /// The window's menu bar shortcuts, tried before the views' keyboard shortcuts.
    var menuShortcut: ((KeyboardShortcut) -> Bool)?
    /// A press nothing took in the title bar row (content that runs up into it): the window drags it.
    var titleBarDrag: ((GdkEventButton) -> Bool)?
    /// The height of that row from the top of the content (zero: none).
    var titleBarDragHeight: (() -> CGFloat)?
    /// After each graph update (the window refreshes its menus, which read app state).
    var onDidUpdate: (() -> Void)?
    /// Widgets of `GtkWidgetRepresentable` views, placed over the canvas in `fixed`.
    var platformWidgets = GtkPlatformWidgets()

    public init(makeGraph: (any RenderBackend) -> ViewGraph) {
        widget = gtk_overlay_new()
        drawingArea = gtk_drawing_area_new()
        fixed = gtk_fixed_new()
        gtk_container_add(sui_container(raw(widget)), drawingArea)
        gtk_overlay_add_overlay(sui_overlay(raw(widget)), fixed)
        gtk_overlay_set_overlay_pass_through(sui_overlay(raw(widget)), fixed, 1)
        gtk_widget_set_can_focus(drawingArea, 1)
        let mask = GDK_BUTTON_PRESS_MASK.rawValue | GDK_BUTTON_RELEASE_MASK.rawValue | GDK_POINTER_MOTION_MASK.rawValue
            | GDK_SCROLL_MASK.rawValue | GDK_SMOOTH_SCROLL_MASK.rawValue | GDK_LEAVE_NOTIFY_MASK.rawValue | GDK_ENTER_NOTIFY_MASK.rawValue
            | GDK_KEY_PRESS_MASK.rawValue | GDK_KEY_RELEASE_MASK.rawValue
        gtk_widget_add_events(drawingArea, Int32(bitPattern: mask))
        backend.host = self
        graph = makeGraph(backend)
        graph.clock = { monotonicSeconds() }
        graph.onNeedsUpdate = { [weak self] in self?.scheduleUpdate() }
        graph.onNeedsAnimationFrame = { [weak self] in self?.startTicking() }
        applyColorScheme()
        connectSignals()
        Self.live.append(Weak(self))
        GtkDebug.log("theme foreground=\(GtkTheme.foreground) background=\(GtkTheme.windowBackground) accent=\(GtkTheme.accent) metrics=\(GtkTheme.metrics)")
    }

    private func connectSignals() {
        let data = unretained(self)
        let draw: @convention(c) (UnsafeMutableRawPointer?, Cairo?, UnsafeMutableRawPointer?) -> gboolean = { _, cr, data in
            MainActor.assumeIsolated { object(data, as: GtkHost.self).draw(cr!) }
            return 1
        }
        connect(raw(drawingArea), "draw", data, draw)
        let allocate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkRectangle>?, UnsafeMutableRawPointer?) -> Void = { _, rect, data in
            guard let rect else { return }
            MainActor.assumeIsolated {
                object(data, as: GtkHost.self).setSize(CGSize(width: CGFloat(rect.pointee.width), height: CGFloat(rect.pointee.height)))
            }
        }
        connect(raw(drawingArea), "size-allocate", data, allocate)
        let scaleChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            MainActor.assumeIsolated {
                let host = object(data, as: GtkHost.self)
                host.setSize(host.size)
            }
        }
        connect(raw(drawingArea), "notify::scale-factor", data, scaleChanged)
        let press: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventButton>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkHost.self).buttonPressed(event.pointee) }.gboolean
        }
        connect(raw(drawingArea), "button-press-event", data, press)
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventButton>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkHost.self).buttonReleased(event.pointee) }.gboolean
        }
        connect(raw(drawingArea), "button-release-event", data, release)
        let motion: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventMotion>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            MainActor.assumeIsolated { object(data, as: GtkHost.self).moved(event.pointee) }
            return 1
        }
        connect(raw(drawingArea), "motion-notify-event", data, motion)
        let leave: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, _, data in
            MainActor.assumeIsolated { object(data, as: GtkHost.self).pointerLeft() }
            return 0
        }
        connect(raw(drawingArea), "leave-notify-event", data, leave)
        let scroll: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventScroll>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkHost.self).scrolled(event.pointee) }.gboolean
        }
        connect(raw(drawingArea), "scroll-event", data, scroll)
        let key: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkHost.self).keyEvent(event.pointee) }.gboolean
        }
        connect(raw(drawingArea), "key-press-event", data, key)
        connect(raw(drawingArea), "key-release-event", data, key)
        let themeChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            MainActor.assumeIsolated {
                GtkTheme.reset()
                let host = object(data, as: GtkHost.self)
                host.applyColorScheme()
                host.flushNow()
            }
        }
        if let settings = gtk_settings_get_default() {
            connect(UnsafeMutableRawPointer(settings), "notify::gtk-theme-name", data, themeChanged)
            connect(UnsafeMutableRawPointer(settings), "notify::gtk-application-prefer-dark-theme", data, themeChanged)
        }
    }

    /// Every host not yet torn down (windows' content and hosted toolbar items), for script mode.
    struct Weak { weak var host: GtkHost?; init(_ host: GtkHost) { self.host = host } }
    static var live: [Weak] = []
    static var all: [GtkHost] { live.compactMap(\.host) }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        Self.live.removeAll { $0.host == nil || $0.host === self }
        if idleSource != 0 { g_source_remove(idleSource) }
        if tickID != 0 { gtk_widget_remove_tick_callback(drawingArea, tickID) }
        idleSource = 0
        tickID = 0
        endEditing(commit: false)
        if let settings = gtk_settings_get_default() {
            // G_SIGNAL_MATCH_DATA; GLib 2.86+ marks GSignalMatchType a flag enum, which Swift imports without the constants
            let matchData = GSignalMatchType(rawValue: 1 << 4)
            g_signal_handlers_disconnect_matched(UnsafeMutableRawPointer(settings), matchData, 0, 0, nil, nil, unretained(self))
        }
        graph.tearDown()
    }

    private func applyColorScheme() {
        let scheme: ColorScheme = sui_prefers_dark() != 0 ? .dark : .light
        graph.setEnvironment { $0.colorScheme = scheme }
    }

    // MARK: Updates

    private func scheduleUpdate() {
        guard idleSource == 0, !isTornDown else { return }
        let callback: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated {
                let host = object(data, as: GtkHost.self)
                host.idleSource = 0
                host.flush()
            }
            return 0
        }
        // Before GTK's redraw (GDK_PRIORITY_REDRAW = G_PRIORITY_HIGH_IDLE + 20).
        idleSource = g_idle_add_full(G_PRIORITY_HIGH_IDLE + 10, callback, unretained(self), nil)
    }

    /// Runs a pending graph update now.
    func flush() {
        guard !isTornDown, graph.needsUpdate else { return }
        graph.update()
        onDidUpdate?()
        GtkMainLoop.serviceTimers()
    }

    func flushNow() {
        if idleSource != 0 {
            g_source_remove(idleSource)
            idleSource = 0
        }
        guard !isTornDown else { return }
        graph.update()
        onDidUpdate?()
        setNeedsDisplay()
        GtkMainLoop.serviceTimers()
    }

    /// An update after the current event (text editing, scrolling).
    func flushSoon() { scheduleUpdate() }

    private var displayScale: CGFloat = 0

    private func setSize(_ size: CGSize) {
        GtkDebug.log("allocate \(size)", level: 3)
        // The window's scale factor (HiDPI) as `displayScale`; known once the widget is realized.
        let scale = CGFloat(max(1, gtk_widget_get_scale_factor(drawingArea)))
        if scale != displayScale {
            displayScale = scale
            graph.setEnvironment { $0.displayScale = scale }
            if size == self.size { flushNow() }
        }
        guard size != self.size else { return }
        self.size = size
        graph.setProposedSize(ProposedViewSize(size))
        flushNow()
        layoutNativeWidgets()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { graph.sizeThatFits(proposal) }

    func setNeedsDisplay() {
        gtk_widget_queue_draw(drawingArea)
    }

    // MARK: Backend callbacks

    private var lastWantsFocus: [ObjectIdentifier: Bool] = [:]

    func contentDidChange(_ node: GtkNode) {
        setNeedsDisplay()
        switch node.content {
        case .textField(let field):
            let id = ObjectIdentifier(node)
            let wanted = lastWantsFocus[id] ?? false
            lastWantsFocus[id] = field.wantsFocus
            node.editor?.apply(field)
            if field.wantsFocus && !wanted && node.editor == nil {
                pendingFocus = node
            } else if !field.wantsFocus && wanted, node.editor != nil {
                pendingEndEditing = true
            }
        case .scrollView(let model):
            applyScrollModel(model, to: node)
        case .platformView:
            platformContentDidChange(node)
        default:
            break
        }
    }

    private weak var pendingFocus: GtkNode?
    private var pendingEndEditing = false

    func nodeRemoved(_ node: GtkNode) {
        if let editing, let edited = editing.node, edited === node || node.descendants.contains(where: { $0 === edited }) {
            endEditing(commit: false)
        }
        if let captured, captured === node || node.descendants.contains(where: { $0 === captured }) { self.captured = nil }
        for input in [input.focus, input.capture] {
            if let input, input === node || node.descendants.contains(where: { $0 === input }) {
                if self.input.focus === input { self.input.focus = nil }
                if self.input.capture === input { self.input.capture = nil }
            }
        }
        hovered.removeAll { hovered in hovered === node || node.descendants.contains { $0 === hovered } }
        lastWantsFocus[ObjectIdentifier(node)] = nil
    }

    func didCommit() {
        setNeedsDisplay()
        if pendingEndEditing {
            pendingEndEditing = false
            endEditing(commit: true)
        }
        if let node = pendingFocus {
            pendingFocus = nil
            // After this update: the field must be in the tree with its final frame.
            DispatchQueue.main.async { [weak self, weak node] in
                guard let self, let node, node.parent != nil || node === self.backend.root else { return }
                self.beginEditing(node)
            }
        }
        layoutNativeWidgets()
    }

    // MARK: Drawing

    private func draw(_ cr: Cairo) {
        let start = GtkDebug.enabled ? monotonicSeconds() : 0
        if drawsBackground {
            GtkTheme.windowBackground.set(cr)
            cairo_paint(cr)
        }
        backend.root.draw(cr, backend: backend)
        GtkDebug.log("draw \(Int(size.width))x\(Int(size.height)) in \(Int((monotonicSeconds() - start) * 1000)) ms", level: 2)
    }

    // MARK: Animation

    private func startTicking() {
        guard tickID == 0, !isTornDown else { return }
        let callback: @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?) -> gboolean = { _, _, data in
            MainActor.assumeIsolated { object(data, as: GtkHost.self).tick() }.gboolean
        }
        tickID = gtk_widget_add_tick_callback(drawingArea, callback, unretained(self), nil)
    }

    private func tick() -> Bool {
        GtkDebug.log("tick \(String(format: "%.3f", monotonicSeconds())) active=\(graph.hasActiveAnimations)", level: 3)
        graph.renderAnimationFrame()
        setNeedsDisplay()
        layoutNativeWidgets()
        if graph.hasActiveAnimations { return true }
        tickID = 0
        return false
    }

    // MARK: Pointer

    private var captured: GtkNode?
    private var capturedInside = false
    /// Views taking raw input (`onGtkInput`): the one with the keyboard and the one holding the pointer.
    private var input = GtkInputRouting()
    private var hovered: [GtkNode] = []
    private var repeatTask: Task<Void, Never>?
    private var cursorName = "default"

    func hitPath(_ point: CGPoint) -> [GtkNode.Hit] {
        backend.root.hitTest(point) ?? []
    }

    func geometricPath(_ point: CGPoint) -> [GtkNode.Hit] {
        backend.root.nodesContaining(point)
    }

    func buttonPressed(_ event: GdkEventButton) -> Bool {
        let point = CGPoint(x: event.x, y: event.y)
        // Double/triple-click events duplicate the presses already delivered (a double click in the title bar row
        // maximizes the window).
        guard event.type == GDK_BUTTON_PRESS else {
            if event.type == GDK_2BUTTON_PRESS, isTitleBarDrag(point, button: event.button) { _ = titleBarDrag?(event) }
            return true
        }
        if editing != nil { endEditing(commit: true) }
        gtk_widget_grab_focus(drawingArea)
        let path = hitPath(point)
        if let node = path.last(where: { $0.node.handlesPointer && $0.node.isEnabled })?.node, node.actions.platformInput != nil {
            if input.focus !== node { sendInput(.focusLost, to: input.focus, state: event.state) }
            input.focus = node
            input.capture = node
            input.buttons.insert(event.button)
            sendInput(
                .buttonDown(button: Int(event.button), clicks: input.clicks(for: event, at: point)), to: node,
                at: point, state: event.state)
            return true
        }
        if let focus = input.focus {
            input.focus = nil
            sendInput(.focusLost, to: focus, state: event.state)
        }
        GtkDebug.log(backend.root.dump(), level: 2)
        GtkDebug.log("press \(event.button) at \(point): \(path.map { "\($0.node.kindName)@\($0.point)" }.joined(separator: " > "))")
        if event.button == 3 {
            if let target = geometricPath(point).last(where: { $0.node.actions.secondaryClick != nil }) {
                target.node.actions.secondaryClick?()
                flushNow()
            }
            return true
        }
        guard event.button == 1, let target = path.last(where: { $0.node.handlesPointer && $0.node.isEnabled }) else {
            if isTitleBarDrag(point, button: event.button) { _ = titleBarDrag?(event) }
            return true
        }
        let node = target.node
        captured = node
        capturedInside = true
        node.isPressed = true
        switch node.content {
        case .button(let button):
            if button.repeats {
                node.actions.primary?()
                startRepeating(node)
            }
        case .slider:
            node.actions.editingChanged?(true)
            setSliderValue(node, x: target.point.x)
        case .textField:
            node.isPressed = false
            captured = nil
            beginEditing(node)
        case .datePicker(let picker):
            node.isPressed = false
            captured = nil
            let rect = node.windowRect().rect
            GtkDialogs.showDatePopover(picker, relativeTo: drawingArea, rect: rect) { [weak self, weak node] date in
                node?.actions.setDate?(date)
                self?.flushNow()
            }
        case .effect:
            node.actions.pressed?(true)
            node.actions.pointer?(PointerEvent(phase: .began, location: target.point, timestamp: monotonicSeconds()))
        default:
            break
        }
        setNeedsDisplay()
        flushNow()
        return true
    }

    /// A press in the title bar row that no view takes.
    private func isTitleBarDrag(_ point: CGPoint, button: guint) -> Bool {
        guard button == 1, let height = titleBarDragHeight?(), point.y < height else { return false }
        return !hitPath(point).contains { $0.node.handlesPointer && $0.node.isEnabled }
    }

    func moved(_ event: GdkEventMotion) {
        let point = CGPoint(x: event.x, y: event.y)
        if let node = input.capture {
            return sendInput(.motion, to: node, at: point, state: event.state)
        }
        if captured == nil, let node = hitPath(point).last(where: { $0.node.handlesPointer })?.node,
            node.actions.platformInput != nil
        {
            sendInput(.motion, to: node, at: point, state: event.state)
        }
        guard let node = captured else { return updateHover(point) }
        let local = node.convertFromWindow(point)
        let inside = node.bounds.contains(local)
        switch node.content {
        case .button, .toggle, .colorWell:
            if inside != node.isPressed {
                node.isPressed = inside
                setNeedsDisplay()
            }
        case .slider:
            setSliderValue(node, x: local.x)
        case .effect:
            if inside != capturedInside { node.actions.pressed?(inside) }
            node.actions.pointer?(PointerEvent(phase: .moved, location: local, timestamp: monotonicSeconds()))
        default:
            break
        }
        capturedInside = inside
        flushNow()
    }

    func buttonReleased(_ event: GdkEventButton) -> Bool {
        if let node = input.capture {
            input.buttons.remove(event.button)
            if input.buttons.isEmpty { input.capture = nil }
            sendInput(
                .buttonUp(button: Int(event.button)), to: node, at: CGPoint(x: event.x, y: event.y), state: event.state)
            return true
        }
        guard event.button == 1, let node = captured else { return true }
        captured = nil
        stopRepeating()
        let local = node.convertFromWindow(CGPoint(x: event.x, y: event.y))
        let inside = node.bounds.contains(local)
        node.isPressed = false
        switch node.content {
        case .button(let button):
            if inside && !button.repeats { node.actions.primary?() }
        case .toggle(var toggle):
            if inside {
                // Like a native check box, the control shows its new state right away (bindings
                // to ObservableObject properties don't re-render the toggle itself).
                let isOn = toggle.isMixed ? true : !toggle.isOn
                toggle.isOn = isOn
                toggle.isMixed = false
                node.content = .toggle(toggle)
                node.actions.setBool?(isOn)
            }
        case .slider:
            setSliderValue(node, x: local.x)
            node.actions.editingChanged?(false)
        case .colorWell(let color):
            if inside {
                GtkDialogs.chooseColor(color, parent: window) { [weak node] color in node?.actions.setColor?(color) }
            }
        case .text(let text):
            if inside, let url = GtkText.link(at: local, in: text, size: node.frame.size) {
                if let open = node.actions.openURL { open(url) } else { backend.openURL(url) }
            }
        case .effect(let effect):
            node.actions.pointer?(PointerEvent(phase: .ended, location: local, timestamp: monotonicSeconds()))
            node.actions.pressed?(false)
            if case .tapTarget = effect, inside { node.actions.primary?() }
        default:
            break
        }
        setNeedsDisplay()
        flushNow()
        updateHover(CGPoint(x: event.x, y: event.y))
        return true
    }

    private func setSliderValue(_ node: GtkNode, x: CGFloat) {
        guard case .slider(var slider) = node.content else { return }
        let (track, _) = GtkTheme.sliderGeometry(size: node.frame.size)
        let fraction = track.width > 0 ? min(max((x - track.minX) / track.width, 0), 1) : 0
        let value = slider.range.lowerBound + Double(fraction) * (slider.range.upperBound - slider.range.lowerBound)
        guard value != slider.value else { return }
        // The knob follows the pointer like a native slider's.
        slider.value = value
        node.content = .slider(slider)
        node.actions.setDouble?(value)
    }

    /// `buttonRepeatBehavior(.enabled)`: fires again after 0.4 s, then every 0.1 s while pressed.
    private func startRepeating(_ node: GtkNode) {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self, weak node] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let self, let node, node.isPressed else { break }
                node.actions.primary?()
                self.flushNow()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    func updateHover(_ point: CGPoint) {
        let path = geometricPath(point)
        let tracked = path.filter { entry in
            let actions = entry.node.actions
            if actions.hover != nil || actions.hoverLocation != nil { return true }
            switch entry.node.content {
            case .button, .toggle, .slider, .datePicker, .colorWell: return true
            default: return false
            }
        }
        var changed = false
        for node in hovered where !tracked.contains(where: { $0.node === node }) {
            node.isHovered = false
            node.actions.hover?(false)
            node.actions.hoverLocation?(nil)
            changed = true
        }
        for entry in tracked {
            if !hovered.contains(where: { $0 === entry.node }) {
                entry.node.isHovered = true
                entry.node.actions.hover?(true)
                changed = true
            }
            if let location = entry.node.actions.hoverLocation {
                GtkDebug.log("hover \(entry.node.kindName) frame \(entry.node.frame) at \(entry.point)", level: 3)
                location(entry.point)
                changed = true
            }
        }
        hovered = tracked.map(\.node)
        updateCursor(path)
        if changed {
            setNeedsDisplay()
            flushNow()
        }
    }

    private func pointerLeft() {
        guard captured == nil else { return }
        for node in hovered {
            node.isHovered = false
            node.actions.hover?(false)
            node.actions.hoverLocation?(nil)
        }
        if !hovered.isEmpty {
            hovered = []
            setNeedsDisplay()
            flushNow()
        }
    }

    private func updateCursor(_ path: [GtkNode.Hit]) {
        var name = "default"
        for entry in path.reversed() {
            if case let .effect(.pointer(style, hidden)) = entry.node.content {
                name = hidden ? "none" : Self.cursorName(style)
                break
            }
            if case .textField(let field) = entry.node.content, field.isEnabled { name = "text"; break }
            if case .text(let text) = entry.node.content, GtkText.link(at: entry.point, in: text, size: entry.node.frame.size) != nil {
                name = "pointer"
                break
            }
        }
        guard name != cursorName, let window = gtk_widget_get_window(drawingArea) else { return }
        cursorName = name
        let cursor = gdk_cursor_new_from_name(gdk_window_get_display(window), name)
        gdk_window_set_cursor(window, cursor)
        if let cursor { g_object_unref(UnsafeMutableRawPointer(cursor)) }
    }

    private static func cursorName(_ style: PointerStyle?) -> String {
        switch style {
        case nil, .default?: "default"
        case .link?: "pointer"
        case .grabIdle?: "grab"
        case .grabActive?: "grabbing"
        case .horizontalText?: "text"
        case .verticalText?: "vertical-text"
        case .rectSelection?: "crosshair"
        case .zoomIn?: "zoom-in"
        case .zoomOut?: "zoom-out"
        case .columnResize?: "col-resize"
        case .rowResize?: "row-resize"
        case .frameResize(let position, _)?:
            switch position {
            case .top: "n-resize"
            case .bottom: "s-resize"
            case .leading: "w-resize"
            case .trailing: "e-resize"
            case .topLeading: "nw-resize"
            case .topTrailing: "ne-resize"
            case .bottomLeading: "sw-resize"
            case .bottomTrailing: "se-resize"
            }
        }
    }

    // MARK: Scrolling

    private var lastScroll: [ObjectIdentifier: Double] = [:]
    private var scrollEndSource: guint = 0
    private weak var scrollingNode: GtkNode?

    func scrollIndicatorsVisible(for node: GtkNode) -> Bool {
        guard let time = lastScroll[ObjectIdentifier(node)] else { return false }
        return monotonicSeconds() - time < 0.8
    }

    private func documentSize(_ model: ResolvedScrollView, viewport: CGSize) -> CGSize {
        CGSize(width: max(model.contentSize.width + model.contentOrigin.x, model.axes.contains(.horizontal) ? 0 : viewport.width),
               height: max(model.contentSize.height + model.contentOrigin.y, model.axes.contains(.vertical) ? 0 : viewport.height))
    }

    private func clamp(_ offset: CGPoint, _ node: GtkNode, _ model: ResolvedScrollView) -> CGPoint {
        let document = documentSize(model, viewport: node.frame.size)
        let maxX = model.axes.contains(.horizontal) ? max(0, document.width - node.frame.width) : 0
        let maxY = model.axes.contains(.vertical) ? max(0, document.height - node.frame.height) : 0
        return CGPoint(x: min(max(offset.x, 0), maxX), y: min(max(offset.y, 0), maxY))
    }

    private func applyScrollModel(_ model: ResolvedScrollView, to node: GtkNode) {
        var offset = node.scrollOffset
        if model.scrollRequestID != node.lastScrollRequestID, let target = model.requestedOffset {
            node.lastScrollRequestID = model.scrollRequestID
            offset = target
        } else if !node.appliedInitialAnchor, let anchor = model.initialAnchor, node.frame.width > 0, node.frame.height > 0 {
            let document = documentSize(model, viewport: node.frame.size)
            if document.width > 0, document.height > 0 {
                node.appliedInitialAnchor = true
                offset = CGPoint(x: max(0, (document.width - node.frame.width) * anchor.x), y: max(0, (document.height - node.frame.height) * anchor.y))
            }
        }
        offset = clamp(offset, node, model)
        if offset != node.scrollOffset {
            node.scrollOffset = offset
            node.actions.scrolled?(offset)
        }
        if model.flashCount > 0 { lastScroll[ObjectIdentifier(node)] = monotonicSeconds() }
    }

    func scrolled(_ event: GdkEventScroll) -> Bool {
        let point = CGPoint(x: event.x, y: event.y)
        if let node = input.capture ?? hitPath(point).last(where: { $0.node.handlesPointer })?.node,
            node.actions.platformInput != nil
        {
            let precise = event.direction == GDK_SCROLL_SMOOTH
            let (wheelX, wheelY): (Double, Double) =
                switch event.direction {
                case GDK_SCROLL_UP: (0, -1)
                case GDK_SCROLL_DOWN: (0, 1)
                case GDK_SCROLL_LEFT: (-1, 0)
                case GDK_SCROLL_RIGHT: (1, 0)
                default: (event.delta_x, event.delta_y)
                }
            sendInput(.scroll(dx: wheelX, dy: wheelY, precise: precise), to: node, at: point, state: event.state)
            return true
        }
        var dx = 0.0, dy = 0.0
        switch event.direction {
        case GDK_SCROLL_UP: dy = -1
        case GDK_SCROLL_DOWN: dy = 1
        case GDK_SCROLL_LEFT: dx = -1
        case GDK_SCROLL_RIGHT: dx = 1
        default: dx = event.delta_x; dy = event.delta_y
        }
        if event.state & GDK_SHIFT_MASK.rawValue != 0, dx == 0 { swap(&dx, &dy) }
        let path = geometricPath(CGPoint(x: event.x, y: event.y))
        for entry in path.reversed() {
            let node = entry.node
            guard let model = node.scrollModel, model.isScrollEnabled else { continue }
            // GTK's scroll step: viewport^(2/3) per wheel notch.
            let stepX = pow(Double(max(node.frame.width, 1)), 2.0 / 3.0), stepY = pow(Double(max(node.frame.height, 1)), 2.0 / 3.0)
            var delta = CGPoint(x: dx * stepX, y: dy * stepY)
            if !model.axes.contains(.vertical), model.axes.contains(.horizontal), delta.x == 0 { delta = CGPoint(x: delta.y, y: 0) }
            let target = clamp(CGPoint(x: node.scrollOffset.x + delta.x, y: node.scrollOffset.y + delta.y), node, model)
            guard target != node.scrollOffset else { continue }
            if scrollingNode !== node {
                scrollingNode?.actions.scrollPhase?(.idle)
                scrollingNode = node
                node.actions.scrollPhase?(.interacting)
            }
            node.scrollOffset = target
            lastScroll[ObjectIdentifier(node)] = monotonicSeconds()
            node.actions.scrolled?(target)
            scheduleScrollEnd()
            setNeedsDisplay()
            layoutNativeWidgets()
            flushNow()
            updateHover(CGPoint(x: event.x, y: event.y))
            return true
        }
        return false
    }

    private func scheduleScrollEnd() {
        if scrollEndSource != 0 { g_source_remove(scrollEndSource) }
        let callback: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated { object(data, as: GtkHost.self).scrollEnded() }
            return 0
        }
        scrollEndSource = g_timeout_add_full(G_PRIORITY_DEFAULT, 150, callback, unretained(self), nil)
    }

    private func scrollEnded() {
        scrollEndSource = 0
        guard let node = scrollingNode, !isTornDown else { return }
        scrollingNode = nil
        if let model = node.scrollModel, let target = node.actions.scrollSnapTarget?(node.scrollOffset) {
            let snapped = clamp(target, node, model)
            if snapped != node.scrollOffset {
                node.scrollOffset = snapped
                node.actions.scrolled?(snapped)
            }
        }
        node.actions.scrollPhase?(.idle)
        flushNow()
        layoutNativeWidgets()
        // Hide the indicators once they time out.
        let hide: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated { object(data, as: GtkHost.self).setNeedsDisplay() }
            return 0
        }
        g_timeout_add_full(G_PRIORITY_DEFAULT, 800, hide, unretained(self), nil)
    }

    // MARK: Keyboard

    static func modifiers(_ state: guint) -> EventModifiers {
        var modifiers: EventModifiers = []
        // Linux's Ctrl plays the role of the Mac's Command key.
        if state & GDK_CONTROL_MASK.rawValue != 0 { modifiers.insert(.command) }
        if state & GDK_SHIFT_MASK.rawValue != 0 { modifiers.insert(.shift) }
        if state & GDK_MOD1_MASK.rawValue != 0 { modifiers.insert(.option) }
        if state & (GDK_SUPER_MASK.rawValue | GDK_META_MASK.rawValue) != 0 { modifiers.insert(.control) }
        return modifiers
    }

    static func keyEquivalent(_ keyval: guint) -> KeyEquivalent? {
        switch Int32(keyval) {
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_ISO_Enter: return .return
        case GDK_KEY_Escape: return .escape
        case GDK_KEY_BackSpace: return .delete
        case GDK_KEY_Delete, GDK_KEY_KP_Delete: return .deleteForward
        case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab: return .tab
        case GDK_KEY_space: return .space
        case GDK_KEY_Up, GDK_KEY_KP_Up: return .upArrow
        case GDK_KEY_Down, GDK_KEY_KP_Down: return .downArrow
        case GDK_KEY_Left, GDK_KEY_KP_Left: return .leftArrow
        case GDK_KEY_Right, GDK_KEY_KP_Right: return .rightArrow
        case GDK_KEY_Home: return .home
        case GDK_KEY_End: return .end
        case GDK_KEY_Page_Up: return .pageUp
        case GDK_KEY_Page_Down: return .pageDown
        default:
            let code = gdk_keyval_to_unicode(sui_keyval_to_lower(keyval))
            guard code != 0, let scalar = Unicode.Scalar(code) else { return nil }
            return KeyEquivalent(Character(scalar))
        }
    }

    /// Key events of the window (forwarded by the window controller) and of the drawing area.
    func keyEvent(_ event: GdkEventKey) -> Bool {
        if let node = input.focus, editing == nil, let handler = node.actions.platformInput {
            let unshifted = GtkInputRouting.unshiftedKeyval(event)
            let kind: GtkInputEvent.Kind =
                event.type == GDK_KEY_PRESS
                ? .keyDown(
                    keyval: event.keyval, unshiftedKeyval: unshifted, keycode: event.hardware_keycode,
                    text: event.string.map { String(cString: $0) } ?? "")
                : .keyUp(keyval: event.keyval, unshiftedKeyval: unshifted, keycode: event.hardware_keycode)
            if handler(GtkInputEvent(kind: kind, location: .zero, state: event.state)) {
                flushNow()
                return true
            }
        }
        guard let key = Self.keyEquivalent(event.keyval) else { return false }
        let modifiers = Self.modifiers(event.state)
        let isPress = event.type == GDK_KEY_PRESS
        let characters = event.string.map { String(cString: $0) } ?? ""
        let editingText = editing?.hasFocus == true
        if editingText {
            // The entry handles typing and its editing shortcuts; others (Ctrl+N, ...) reach the app.
            guard isPress, modifiers.contains(.command) || modifiers.contains(.option) else { return false }
            let editingKeys: Set<Character> = ["a", "c", "v", "x", "z", "y"]
            if modifiers == .command || modifiers == [.command, .shift], editingKeys.contains(key.character) { return false }
        }
        if !editingText, graph.handleKeyPress(KeyPress(key: key, characters: characters, modifiers: modifiers, phase: isPress ? .down : .up)) {
            flushNow()
            return true
        }
        guard isPress else { return false }
        if menuShortcut?(KeyboardShortcut(key, modifiers: modifiers)) == true || graph.performKeyboardShortcut(KeyboardShortcut(key, modifiers: modifiers)) {
            flushNow()
            return true
        }
        // Shortcuts declared with `.control` (Ctrl+key on Linux too).
        if modifiers.contains(.command) {
            var alternate = modifiers
            alternate.remove(.command)
            alternate.insert(.control)
            if graph.performKeyboardShortcut(KeyboardShortcut(key, modifiers: alternate)) {
                flushNow()
                return true
            }
        }
        if !editingText, key == .tab {
            focusNextField(from: nil, backwards: modifiers.contains(.shift))
            return true
        }
        // Escape closes the topmost sheet, alert, dialog, popover or menu (like Android's Back).
        if key == .escape, modifiers.isEmpty, graph.dismissTopPresentation() {
            flushNow()
            return true
        }
        return false
    }

    /// Delivers a raw input event to a view taking them (`onGtkInput`); `point` is in the window.
    private func sendInput(_ kind: GtkInputEvent.Kind, to node: GtkNode?, at point: CGPoint? = nil, state: guint) {
        guard let node, let handler = node.actions.platformInput else { return }
        let location = point.map { node.convertFromWindow($0) } ?? .zero
        _ = handler(GtkInputEvent(kind: kind, location: location, state: state))
        flushNow()
    }

    // MARK: Text editing

    private(set) var editing: GtkTextEditor?

    func beginEditing(_ node: GtkNode) {
        guard case .textField(let field) = node.content, field.isEnabled, !isTornDown else { return }
        if let editing, editing.node === node {
            editing.focus()
            return
        }
        endEditing(commit: true)
        let editor = GtkTextEditor(host: self, node: node, field: field)
        node.editor = editor
        editing = editor
        gtk_fixed_put(sui_fixed(raw(fixed)), editor.container, 0, 0)
        layoutNativeWidgets()
        gtk_widget_show_all(editor.container)
        editor.focus()
        node.actions.focusChanged?(true)
        graph.setFocusedNode(node.node)
        setNeedsDisplay()
        flushNow()
    }

    func endEditing(editor: GtkTextEditor? = nil, commit: Bool = true) {
        guard let current = editing, editor == nil || editor === current else { return }
        editing = nil
        let node = current.node
        node?.editor = nil
        current.destroy()
        guard !isTornDown else { return }
        node?.actions.focusChanged?(false)
        graph.setFocusedNode(nil)
        gtk_widget_grab_focus(drawingArea)
        setNeedsDisplay()
        flushSoon()
    }

    /// Tab / Shift-Tab between text fields (in drawing order).
    func focusNextField(from node: GtkNode?, backwards: Bool) {
        let fields = backend.root.descendants.filter { candidate in
            guard case .textField(let field) = candidate.content, field.isEnabled else { return false }
            return candidate.windowRect().visible.height > 1
        }
        guard !fields.isEmpty else { return }
        var index = node.flatMap { current in fields.firstIndex { $0 === current } } ?? (backwards ? fields.count : -1)
        index = (index + (backwards ? -1 : 1) + fields.count) % fields.count
        beginEditing(fields[index])
    }

    /// Positions native widgets over their nodes (after layout, scrolling and animation frames).
    func layoutNativeWidgets() {
        layoutPlatformWidgets()
        guard let editing, let node = editing.node else { return }
        let (rect, visible) = node.windowRect()
        if visible.height < min(rect.height, 8) || visible.width < 8 {
            gtk_widget_hide(editing.container)
            return
        }
        gtk_widget_show(editing.container)
        gtk_fixed_move(sui_fixed(raw(fixed)), editing.container, Int32(rect.minX.rounded()), Int32(rect.minY.rounded()))
        gtk_widget_set_size_request(editing.container, Int32(rect.width.rounded()), Int32(rect.height.rounded()))
    }
}
#endif
