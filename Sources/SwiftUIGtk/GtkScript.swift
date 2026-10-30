#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Script mode: drives the app for automated checks, like the WinUI host's `--script`. Started by
/// `--script <file>` (or `SWIFTUI_SCRIPT=<file>`); runs on the main loop once the first window is up,
/// one command per line (`#` starts a comment):
///
///     wait <ms>                    pause (the app keeps running)
///     waitfor <text> [ms]          wait until a text (or field placeholder) shows, up to ms (default 5000)
///     screenshot <png>             the current window's content, header bar included (drawn by GTK, so it
///                                  works when the window is covered or on Xvfb)
///     screen <png>                 the whole X screen (menus and dialogs are windows of their own)
///     dump <txt> [all]             the window's view tree, frames in screenshot points (`-`: stderr); views out of
///                                  sight are left out unless `all`
///     tap <text>                   clicks the text (a button's label, a row, a field's placeholder,
///                                  `image:<SF Symbol>`), else a header bar button with that label or tooltip
///     tapat <x> <y>                clicks at a point (screenshot points)   ·   rclick <x> <y>: right click
///     hover <x> <y>                moves the pointer there
///     scroll <x> <y> <dy> [dx]     wheel notches over a point (positive: down)
///     type <text>                  sets the focused (else the first) text field's text
///     fill <placeholder>|<text>    sets the text of the field with that placeholder or form row label (`#n`: the nth)
///     keys <text>                  key presses to the focused view (`\n` Return, `\t` Tab, `\e` Escape)
///     key <combo>                  one key, GDK names and modifiers: `ctrl+n`, `ctrl+shift+s`, `Escape`, `Down`
///     menu <Menu>/<Item>[/<Sub>]   runs a menu bar item (`File/New Window`)
///     back                         Escape: dismisses the top presentation, else navigates back
///     window <n|title>             makes another window current (1-based, in opening order)
///     windows                      lists the windows (stderr)
///     resize <w> <h>               resizes the current window
///     expect <text>                fails (exit status 1 at the end) unless the text shows
///     log <message>                writes to stderr
///     exit                         quits (status 1 if an expect failed)
///
/// Output goes to stderr with a `[script]` prefix. Run headless with `xvfb-run -a <app> --script <file>`.
@MainActor
enum GtkScript {
    private static var lines: [String] = []
    private static var index = 0
    private static var current: GtkWindowController?
    private static var failures = 0
    private static var started = false

    /// The script file from the command line (`--script <file>`) or the environment.
    static var requestedPath: String? {
        let arguments = CommandLine.arguments
        if let at = arguments.firstIndex(of: "--script"), at + 1 < arguments.count { return arguments[at + 1] }
        return ProcessInfo.processInfo.environment["SWIFTUI_SCRIPT"]
    }

    /// Starts the script, if one was asked for, after the windows opened at launch are shown.
    static func startIfRequested() {
        guard !started, let path = requestedPath else { return }
        started = true
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            report("can't read \(path)")
            exit(2)
        }
        lines = text.components(separatedBy: .newlines)
        report("running \(path) (\(lines.count) lines)")
        schedule(after: 300)
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data(("[script] " + message + "\n").utf8))
    }

    /// Bumped by each scheduled step: a step whose generation is stale doesn't run (a screenshot taken after the
    /// next frame steps on at once, and its fallback timeout then finds nothing to do).
    private static var generation = 0

    private static func schedule(after milliseconds: Int) {
        generation += 1
        let callback: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated {
                guard Int(bitPattern: data) == GtkScript.generation else { return }
                GtkScript.step()
            }
            return 0
        }
        g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(0, milliseconds)), callback, UnsafeMutableRawPointer(bitPattern: generation), nil)
    }

    private static var pendingShot: String?

    /// Takes the screenshot once GTK has painted the next frame (its layout done), or after a second when no frame
    /// comes (an unmapped window).
    private static func screenshotAfterNextFrame(path: String) -> Int {
        // A window being mapped (or re-realized, as when content moves into the title bar) draws nothing yet.
        let line = index - 1
        if let controller = window(), gtk_widget_get_mapped(controller.window) == 0 || gtk_widget_get_mapped(controller.host.drawingArea) == 0 {
            let deadline = pendingDeadline[line] ?? monotonicSeconds() + 3
            if monotonicSeconds() < deadline {
                pendingDeadline[line] = deadline
                index = line
                return 100
            }
        }
        pendingDeadline[line] = nil
        guard let controller = window(), let clock = gtk_widget_get_frame_clock(controller.window) else {
            screenshot(path: path)
            return 0
        }
        pendingShot = path
        if paintClock != UnsafeMutableRawPointer(clock) {
            let afterPaint: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _ in
                MainActor.assumeIsolated { GtkScript.framePainted() }
            }
            connect(UnsafeMutableRawPointer(clock), "after-paint", nil, afterPaint)
            paintClock = UnsafeMutableRawPointer(clock)
        }
        gtk_widget_queue_draw(controller.window)
        return 1000
    }

    private static var paintClock: UnsafeMutableRawPointer?

    private static func framePainted() {
        guard let path = pendingShot else { return }
        pendingShot = nil
        // After this frame's handlers: the shot itself draws the window again.
        let callback: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated {
                guard Int(bitPattern: data) == GtkScript.generation, let path = GtkScript.shotPath else { return }
                GtkScript.shotPath = nil
                // The fallback step is stale now: taking the shot runs the main loop (settle), where it could
                // otherwise fire, go on and exit before the file is written (slow pages).
                GtkScript.generation += 1
                GtkScript.screenshot(path: path)
                GtkScript.schedule(after: 0)
            }
            return 0
        }
        shotPath = path
        g_idle_add_full(G_PRIORITY_DEFAULT, callback, UnsafeMutableRawPointer(bitPattern: generation), nil)
    }

    private static var shotPath: String?
    private static var stepping = false

    /// Runs commands until one waits.
    private static func step() {
        // Commands run the main loop (settle, waits); a step timer firing in there belongs to this step.
        guard !stepping else { return }
        stepping = true
        defer { stepping = false }
        // No frame came for a screenshot (an unmapped window): take it as things are.
        if let path = pendingShot ?? shotPath {
            pendingShot = nil
            shotPath = nil
            screenshot(path: path)
        }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            let command: String, argument: String
            if let space = line.firstIndex(of: " ") {
                command = String(line[..<space])
                argument = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            } else {
                command = line
                argument = ""
            }
            flushAll()
            if let delay = run(command, argument) {
                schedule(after: delay)
                return
            }
            flushAll()
        }
        finish()
    }

    private static func finish() -> Never {
        report(failures == 0 ? "done" : "done, \(failures) expectation(s) failed")
        UserDefaults.standard.synchronize()
        exit(failures == 0 ? 0 : 1)
    }

    /// Runs one command; returns a delay before the next one (nil: go on at once).
    private static func run(_ command: String, _ argument: String) -> Int? {
        switch command {
        case "wait":
            return Int(argument) ?? 1000
        case "waitfor":
            var parts = argument.split(separator: " ").map(String.init)
            var timeout = 5000
            if parts.count > 1, let ms = Int(parts.last!) { timeout = ms; parts.removeLast() }
            let line = index - 1
            let deadline = pendingDeadline[line] ?? monotonicSeconds() + Double(timeout) / 1000
            return waitFor(parts.joined(separator: " "), until: deadline)
        case "screenshot":
            return screenshotAfterNextFrame(path: argument)
        case "screen":
            screen(path: argument)
        case "dump":
            // `dump <path> all` keeps the views scrolled or clipped out of sight.
            var path = argument
            var all = false
            if path.hasSuffix(" all") { path = String(path.dropLast(4)); all = true }
            let text = dump(all: all)
            if path.isEmpty || path == "-" {
                FileHandle.standardError.write(Data(text.utf8))
            } else {
                write(text, to: path)
            }
        case "tap":
            if !tap(argument) { report("tap: nothing to tap around \"\(argument)\"") }
        case "tapat", "click":
            guard let point = point(argument) else { report("\(command): expected <x> <y>"); break }
            if !click(at: point, button: 1) { report("tapat: nothing at \(argument)") }
        case "rclick":
            guard let point = point(argument) else { report("rclick: expected <x> <y>"); break }
            _ = click(at: point, button: 3)
        case "hover":
            guard let point = point(argument), let (host, local) = hostAt(point) else { break }
            host.updateHover(local)
        case "scroll":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count >= 3, let (host, local) = hostAt(CGPoint(x: numbers[0], y: numbers[1])) else {
                report("scroll: expected <x> <y> <dy> [dx]")
                break
            }
            var event = GdkEventScroll()
            event.type = GDK_SCROLL
            event.direction = GDK_SCROLL_SMOOTH
            event.x = Double(local.x)
            event.y = Double(local.y)
            event.delta_y = numbers[2]
            event.delta_x = numbers.count > 3 ? numbers[3] : 0
            _ = host.scrolled(event)
        case "type":
            guard let (host, node) = focusedField() ?? fields().first else { report("type: no text field"); break }
            setText(argument, of: node, in: host)
        case "fill":
            guard let bar = argument.firstIndex(of: "|") else { report("fill: expected <placeholder>|<text>"); break }
            let key = String(argument[..<bar]), text = String(argument[argument.index(after: bar)...])
            let all = fields()
            var target: (GtkHost, GtkNode)?
            if key.hasPrefix("#"), let n = Int(key.dropFirst()), n >= 1, n <= all.count {
                target = all[n - 1]
            } else {
                target = all.first { if case .textField(let field) = $0.1.content { field.placeholder == key } else { false } }
                    ?? all.first { formLabel(of: $0.1, among: $0.0.backend.root.descendants) == key }
            }
            guard let (host, node) = target else { report("fill: no text field \"\(key)\""); break }
            setText(text, of: node, in: host)
        case "keys":
            var text = argument.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            text = text.replacingOccurrences(of: "\\e", with: "\u{1B}")
            for character in text { sendKey(keyval(for: character), modifiers: 0) }
        case "key":
            guard let (keyval, modifiers) = parseCombo(argument) else { report("key: unknown key \"\(argument)\""); break }
            sendKey(keyval, modifiers: modifiers)
        case "menu":
            guard let controller = window() else { break }
            let path = argument.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if !controller.menuBar.perform(path: path) { report("menu: no enabled item \(argument)") }
        case "back":
            if let controller = window() { _ = controller.back() }
        case "window":
            let controllers = GtkAppRunner.controllers
            if let n = Int(argument), n >= 1, n <= controllers.count {
                current = controllers[n - 1]
            } else if let match = controllers.first(where: { $0.currentTitle.localizedCaseInsensitiveContains(argument) }) {
                current = match
            } else {
                report("window: no window \(argument)")
            }
        case "windows":
            for (n, controller) in GtkAppRunner.controllers.enumerated() {
                let size = controller.visibleFrame.size
                report("\(n + 1): \"\(controller.currentTitle)\" \(Int(size.width))x\(Int(size.height))\(controller === window() ? " (current)" : "")")
            }
        case "resize":
            let numbers = argument.split(separator: " ").compactMap { Int32($0) }
            guard numbers.count == 2, let controller = window() else { report("resize: expected <w> <h>"); break }
            gtk_window_resize(sui_window(raw(controller.window)), numbers[0], numbers[1])
            return 300
        case "expect":
            if find(argument).isEmpty {
                failures += 1
                report("FAIL expect \"\(argument)\"")
            } else {
                report("ok \"\(argument)\"")
            }
        case "log":
            report(argument)
        case "exit":
            finish()
        default:
            report("unknown command \(command)")
        }
        return nil
    }

    // MARK: Windows

    /// The current window: the one selected with `window`, else the newest.
    static func window() -> GtkWindowController? {
        if let current, GtkAppRunner.controllers.contains(where: { $0 === current }) { return current }
        current = nil
        return GtkAppRunner.controllers.last
    }

    /// The hosts drawn in the current window (its content, hosted toolbar items), with their content origins in
    /// screenshot points.
    private static func hosts() -> [(host: GtkHost, origin: CGPoint)] {
        guard let controller = window() else { return [] }
        let frame = controller.visibleFrame
        var result: [(GtkHost, CGPoint)] = []
        for host in GtkHost.all where gtk_widget_get_toplevel(host.widget) == controller.window && gtk_widget_get_mapped(host.drawingArea) != 0 {
            var x: Int32 = 0, y: Int32 = 0
            gtk_widget_translate_coordinates(host.drawingArea, controller.window, 0, 0, &x, &y)
            result.append((host, CGPoint(x: CGFloat(x) - frame.minX, y: CGFloat(y) - frame.minY)))
        }
        // The window's content first (toolbar hosts sit above it in the header bar).
        return result.sorted { $0.0 === controller.host && $1.0 !== controller.host }
    }

    private static func flushAll() {
        for host in GtkHost.all { host.flush() }
    }

    /// The host under a point (screenshot points) and the point in its coordinates.
    private static func hostAt(_ point: CGPoint) -> (GtkHost, CGPoint)? {
        for (host, origin) in hosts().reversed() {
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            if CGRect(origin: .zero, size: host.size).contains(local) { return (host, local) }
        }
        return nil
    }

    // MARK: Finding views

    struct Match {
        let host: GtkHost
        let node: GtkNode
        /// The visible rect in screenshot points.
        let rect: CGRect
    }

    /// Nodes showing `text` (exact matches first): texts, field placeholders and text, `image:<name>` symbols.
    private static func find(_ text: String) -> [Match] {
        var exact: [Match] = [], partial: [Match] = []
        for (host, origin) in hosts() {
            let nodes = host.backend.root.descendants
            for node in nodes {
                let strings: [String]
                switch node.content {
                case .text(let resolved): strings = [resolved.string]
                case .textField(let field): strings = [field.placeholder, field.text] + (formLabel(of: node, among: nodes).map { [$0] } ?? [])
                case .image(let image):
                    if case .system(let name) = image.source { strings = ["image:" + name] } else { strings = [] }
                default: strings = []
                }
                guard !strings.isEmpty else { continue }
                let visible = node.windowRect().visible
                guard visible.width >= 1, visible.height >= 1, host.isVisible(node) else { continue }
                let match = Match(host: host, node: node, rect: visible.offsetBy(dx: origin.x, dy: origin.y))
                if strings.contains(text) { exact.append(match) } else if strings.contains(where: { $0.contains(text) }) { partial.append(match) }
            }
        }
        return exact + partial
    }

    /// The label of a field in a form row (a text on its left, on the same line): grouped forms show the title
    /// there instead of a placeholder.
    static func formLabel(of field: GtkNode, among nodes: [GtkNode]) -> String? {
        guard case .textField(let resolved) = field.content, resolved.placeholder.isEmpty else { return nil }
        let rect = field.windowRect().rect
        var best: (String, CGFloat)?
        for node in nodes {
            guard case .text(let text) = node.content else { continue }
            let r = node.windowRect().rect
            guard r.maxX <= rect.minX + 1, abs(r.midY - rect.midY) < max(rect.height, 12) / 2 + 4 else { continue }
            let distance = rect.minX - r.maxX
            if best == nil || distance < best!.1 { best = (text.string, distance) }
        }
        return best?.0
    }

    private static func waitFor(_ text: String, until deadline: Double) -> Int? {
        let line = index - 1
        if !find(text).isEmpty || headerButton(text) != nil {
            pendingDeadline[line] = nil
            report("found \"\(text)\"")
            return nil
        }
        if monotonicSeconds() >= deadline {
            pendingDeadline[line] = nil
            failures += 1
            report("FAIL waitfor \"\(text)\": not shown")
            return nil
        }
        // Check again shortly: step back so the line runs again.
        index = line
        pendingDeadline[line] = deadline
        return 100
    }

    private static var pendingDeadline: [Int: Double] = [:]

    // MARK: Pointer

    private static func tap(_ text: String) -> Bool {
        for match in find(text) {
            let center = CGPoint(x: match.rect.midX, y: match.rect.midY)
            if click(at: center, button: 1, requireHandler: true) { return true }
        }
        if let button = headerButton(text) {
            gtk_button_clicked(sui_button(raw(button)))
            return true
        }
        return false
    }

    /// Clicks at a point (screenshot points). With `requireHandler`, only when something there takes the click.
    @discardableResult
    private static func click(at point: CGPoint, button: guint, requireHandler: Bool = false) -> Bool {
        guard let (host, local) = hostAt(point) else { return false }
        if requireHandler {
            let path = button == 3 ? host.geometricPath(local) : host.hitPath(local)
            let handled = button == 3
                ? path.contains { $0.node.actions.secondaryClick != nil }
                : path.contains { $0.node.handlesPointer && $0.node.isEnabled }
            guard handled else { return false }
        }
        host.updateHover(local)
        var event = GdkEventButton()
        event.type = GDK_BUTTON_PRESS
        event.button = button
        event.x = Double(local.x)
        event.y = Double(local.y)
        event.time = guint32(GDK_CURRENT_TIME)
        _ = host.buttonPressed(event)
        event.type = GDK_BUTTON_RELEASE
        _ = host.buttonReleased(event)
        return true
    }

    private static func point(_ argument: String) -> CGPoint? {
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    /// A header bar button whose label or tooltip is `text`.
    private static func headerButton(_ text: String) -> UnsafeMutablePointer<GtkWidget>? {
        guard let controller = window() else { return nil }
        var found: UnsafeMutablePointer<GtkWidget>?
        visitWidgets(controller.headerBar) { widget in
            guard found == nil, gtk_widget_is_visible(widget) != 0, g_type_check_instance_is_a(UnsafeMutablePointer(OpaquePointer(widget)), gtk_button_get_type()) != 0 else { return }
            let label = gtk_button_get_label(sui_button(raw(widget))).map { String(cString: $0) }
            let tip = gtk_widget_get_tooltip_text(widget).map { pointer in
                defer { g_free(pointer) }
                return String(cString: pointer)
            }
            if label == text || tip == text { found = widget }
        }
        return found
    }

    static func visitWidgets(_ widget: UnsafeMutablePointer<GtkWidget>, _ body: (UnsafeMutablePointer<GtkWidget>) -> Void) {
        body(widget)
        guard g_type_check_instance_is_a(UnsafeMutablePointer(OpaquePointer(widget)), gtk_container_get_type()) != 0 else { return }
        let list = gtk_container_get_children(sui_container(raw(widget)))
        var item = list
        while let current = item {
            if let child = current.pointee.data { visitWidgets(child.assumingMemoryBound(to: GtkWidget.self), body) }
            item = current.pointee.next
        }
        g_list_free(list)
    }

    // MARK: Text

    private static func fields() -> [(GtkHost, GtkNode)] {
        hosts().flatMap { entry in
            entry.host.backend.root.descendants.filter { node in
                if case .textField = node.content { return entry.host.isVisible(node) }
                return false
            }.map { (entry.host, $0) }
        }
    }

    private static func focusedField() -> (GtkHost, GtkNode)? {
        for (host, _) in hosts() {
            if let editing = host.editing, let node = editing.node { return (host, node) }
        }
        return nil
    }

    /// Edits the field and sets its text through the native entry, as typing would.
    private static func setText(_ text: String, of node: GtkNode, in host: GtkHost) {
        host.beginEditing(node)
        if let editor = host.editing, editor.node === node {
            editor.setText(text)
        } else {
            node.actions.setText?(text)
        }
        host.flushNow()
    }

    // MARK: Keys

    private static func keyval(for character: Character) -> guint {
        switch character {
        case "\n", "\r": return guint(GDK_KEY_Return)
        case "\t": return guint(GDK_KEY_Tab)
        case "\u{1B}": return guint(GDK_KEY_Escape)
        case "\u{8}": return guint(GDK_KEY_BackSpace)
        default: return gdk_unicode_to_keyval(character.unicodeScalars.first!.value)
        }
    }

    /// "ctrl+shift+s", "alt+Left", "Escape", "F5".
    private static func parseCombo(_ combo: String) -> (guint, guint)? {
        var parts = combo.split(separator: "+").map(String.init)
        guard let name = parts.popLast(), !name.isEmpty else { return nil }
        var modifiers: guint = 0
        for part in parts {
            switch part.lowercased() {
            case "ctrl", "control", "cmd", "command": modifiers |= GDK_CONTROL_MASK.rawValue
            case "shift": modifiers |= GDK_SHIFT_MASK.rawValue
            case "alt", "option", "opt": modifiers |= GDK_MOD1_MASK.rawValue
            case "super", "win", "meta": modifiers |= GDK_SUPER_MASK.rawValue
            default: return nil
            }
        }
        var value = gdk_keyval_from_name(name)
        if value == guint(GDK_KEY_VoidSymbol) || value == 0 {
            guard name.count == 1, let character = name.first else { return nil }
            value = keyval(for: character)
        }
        return (value, modifiers)
    }

    /// A key press and release through GTK's event dispatch (the focused entry gets it as typed).
    private static func sendKey(_ keyval: guint, modifiers: guint) {
        guard let controller = window(), let gdkWindow = gtk_widget_get_window(controller.window) else { return }
        let display = gdk_window_get_display(gdkWindow)
        let keyboard = gdk_seat_get_keyboard(gdk_display_get_default_seat(display))
        var keycode: guint16 = 0
        var keys: UnsafeMutablePointer<GdkKeymapKey>?
        var count: Int32 = 0
        if gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(display), keyval, &keys, &count) != 0, let keys {
            keycode = guint16(keys.pointee.keycode)
            g_free(keys)
        }
        let unicode = gdk_keyval_to_unicode(keyval)
        for type in [GDK_KEY_PRESS, GDK_KEY_RELEASE] {
            guard let event = gdk_event_new(type) else { continue }
            event.pointee.key.window = OpaquePointer(g_object_ref(UnsafeMutableRawPointer(gdkWindow)))
            event.pointee.key.send_event = 1
            event.pointee.key.time = guint32(GDK_CURRENT_TIME)
            event.pointee.key.state = modifiers
            event.pointee.key.keyval = keyval
            event.pointee.key.hardware_keycode = keycode
            if unicode >= 0x20, unicode != 0x7F, let scalar = Unicode.Scalar(unicode), modifiers & GDK_CONTROL_MASK.rawValue == 0 {
                let string = String(Character(scalar))
                event.pointee.key.string = g_strdup(string)
                event.pointee.key.length = Int32(string.utf8.count)
            }
            if let keyboard { gdk_event_set_device(event, keyboard) }
            gtk_main_do_event(event)
            gdk_event_free(event)
        }
        flushAll()
    }

    // MARK: Screenshots and dumps

    private static func write(_ text: String, to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { report("can't write \(path): \(error)") }
    }

    /// The window drawn by GTK into an image (no compositor or visible window needed), cropped to its frame
    /// (client-side decorations add shadow margins around it).
    private static func screenshot(path: String) {
        guard let controller = window() else { report("screenshot: no window"); return }
        settle(controller)
        let frame = controller.visibleFrame
        let scale = Double(max(1, gtk_widget_get_scale_factor(controller.window)))
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(Double(frame.width) * scale), Int32(Double(frame.height) * scale))
        cairo_surface_set_device_scale(surface, scale, scale)
        let cr = cairo_create(surface)
        cairo_translate(cr, -Double(frame.minX), -Double(frame.minY))
        gtk_widget_draw(controller.window, cr)
        cairo_destroy(cr)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let status = cairo_surface_write_to_png(surface, path)
        cairo_surface_destroy(surface)
        if status != CAIRO_STATUS_SUCCESS { report("screenshot: can't write \(path)") }
    }

    /// Lets GTK handle what is pending (updates, resizes) and lays the window out, so it draws as it is now.
    private static func settle(_ controller: GtkWindowController) {
        for _ in 0..<200 where gtk_events_pending() != 0 { gtk_main_iteration_do(0) }
        gtk_container_check_resize(sui_container(raw(controller.window)))
        // A resize still pending (the window settling at launch) would make GTK refuse to draw it: lay it out at its
        // current size.
        var allocation = GtkAllocation()
        gtk_widget_get_allocation(controller.window, &allocation)
        gtk_widget_size_allocate(controller.window, &allocation)
    }

    /// The X screen (popup menus, dialogs and popovers included).
    private static func screen(path: String) {
        guard let root = gdk_get_default_root_window() else { return }
        let width = gdk_window_get_width(root), height = gdk_window_get_height(root)
        guard let pixbuf = gdk_pixbuf_get_from_window(root, 0, 0, width, height) else { report("screen: can't capture"); return }
        var error: UnsafeMutablePointer<GError>?
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        sui_pixbuf_save_png(pixbuf, path, &error)
        if let error {
            report("screen: \(String(cString: error.pointee.message))")
            g_error_free(error)
        }
        g_object_unref(UnsafeMutableRawPointer(pixbuf))
    }

    /// One line per node: kind, frame in screenshot points (x, y, width, height), what it shows and its state.
    static func dump(all: Bool = false) -> String {
        guard let controller = window() else { return "no window\n" }
        var out = ""
        let size = controller.visibleFrame.size
        out += "window \"\(controller.currentTitle)\" \(Int(size.width))x\(Int(size.height)) @\(gtk_widget_get_scale_factor(controller.window))x\n"
        visitWidgets(controller.headerBar) { widget in
            guard gtk_widget_is_visible(widget) != 0, g_type_check_instance_is_a(UnsafeMutablePointer(OpaquePointer(widget)), gtk_button_get_type()) != 0 else { return }
            let label = gtk_button_get_label(sui_button(raw(widget))).map { String(cString: $0) } ?? ""
            let tip = gtk_widget_get_tooltip_text(widget).map { pointer in
                defer { g_free(pointer) }
                return String(cString: pointer)
            } ?? ""
            var x: Int32 = 0, y: Int32 = 0
            gtk_widget_translate_coordinates(widget, controller.window, 0, 0, &x, &y)
            let frame = controller.visibleFrame
            out += "HeaderButton (\(Int(x) - Int(frame.minX)), \(Int(y) - Int(frame.minY)), \(gtk_widget_get_allocated_width(widget)), \(gtk_widget_get_allocated_height(widget)))"
            out += " \"\(label.isEmpty ? tip : label)\"\(gtk_widget_get_sensitive(widget) == 0 ? " disabled" : "")\n"
        }
        out += controller.menuBar.dump()
        var count = 0
        for (host, origin) in hosts() {
            let nodes = host.backend.root.descendants
            out += host === controller.host ? "content at (\(F(origin.x)), \(F(origin.y)))\n" : "toolbar item at (\(F(origin.x)), \(F(origin.y)))\n"
            func visit(_ node: GtkNode, depth: Int) {
                count += 1
                let (rect, visible) = node.windowRect()
                let shown = visible.width >= 1 && visible.height >= 1 && node.presentation.opacity > 0
                if !shown && !all { return }
                if case .effect(.opacity(let value)) = node.content, value <= 0, !all { return }
                let r = rect.offsetBy(dx: origin.x, dy: origin.y)
                out += String(repeating: "  ", count: depth) + "\(describe(node)) (\(F(r.minX)), \(F(r.minY)), \(F(r.width)), \(F(r.height)))"
                if let label = formLabel(of: node, among: nodes) { out += " label \"\(label)\"" }
                if !shown { out += " hidden" }
                out += "\n"
                for child in node.children { visit(child, depth: depth + 1) }
            }
            for child in host.backend.root.children { visit(child, depth: 1) }
        }
        out += "END \(count) nodes\n"
        return out
    }

    private static func F(_ value: CGFloat) -> String {
        abs(value - value.rounded()) < 0.05 ? String(Int(value.rounded())) : String(format: "%.1f", Double(value))
    }

    private static func describe(_ node: GtkNode) -> String {
        let actions = node.actions
        var flags: [String] = []
        if actions.primary != nil { flags.append("tap") }
        if actions.secondaryClick != nil { flags.append("menu") }
        if actions.pointer != nil { flags.append("pointer") }
        if !node.isEnabled { flags.append("disabled") }
        let suffix = flags.isEmpty ? "" : " [" + flags.joined(separator: ",") + "]"
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\"" }
        switch node.content {
        case .empty: return "Group" + suffix
        case .text(let text): return "Text " + quoted(text.string) + suffix
        case .color(let c): return String(format: "Color #%02X%02X%02X%@", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255), c.opacity < 1 ? String(format: " %.2f", c.opacity) : "")
        case .shape: return "Shape" + suffix
        case .image(let image):
            switch image.source {
            case .system(let name): return "Image image:\(name)" + suffix
            case .named(let name): return "Image \(name)" + suffix
            case .platform: return "Image" + suffix
            }
        case .button(let button): return "Button \(button.style)\(button.isOn ? " on" : "")" + suffix
        case .toggle(let toggle): return "Toggle \(toggle.style) \(toggle.isMixed ? "mixed" : toggle.isOn ? "on" : "off")" + suffix
        case .textField(let field):
            return "TextField " + quoted(field.text) + " placeholder " + quoted(field.placeholder) + (node.editor != nil ? " editing" : "") + suffix
        case .slider(let slider): return "Slider \(slider.value) in \(slider.range)" + suffix
        case .scrollView(let model):
            return "ScrollView \(model.axes == .vertical ? "vertical" : model.axes == .horizontal ? "horizontal" : "both") offset (\(F(node.scrollOffset.x)), \(F(node.scrollOffset.y))) content \(F(model.contentSize.width))x\(F(model.contentSize.height))" + suffix
        case .effect(let effect):
            let name: String
            switch effect {
            case .opacity(let value): name = "Opacity \(value)"
            case .clip: name = "Clip"
            case .tapTarget: name = "TapTarget"
            case .transform: name = "Transform"
            case .projection: name = "Projection"
            case .shadow: name = "Shadow"
            case .mask: name = "Mask"
            case .maskSource: name = "MaskSource"
            case .group: name = "Group"
            case .focusable(let wants, _): name = "Focusable\(wants ? " focused" : "")"
            case .pointer: name = "Pointer"
            case .colorFilter: name = "ColorFilter"
            case .blendMode: name = "BlendMode"
            case .contentShape: name = "ContentShape"
            }
            return name + suffix
        case .datePicker(let picker): return "DatePicker \(picker.date)" + suffix
        case .colorWell: return "ColorWell" + suffix
        case .drawing: return "Canvas" + suffix
        case .platformView: return "PlatformView" + suffix
        }
    }
}

extension GtkHost {
    /// Whether the node is drawn: it and its ancestors have nonzero opacity and aren't mask sources.
    func isVisible(_ node: GtkNode) -> Bool {
        var current: GtkNode? = node
        while let n = current {
            if n.presentation.opacity <= 0 { return false }
            if case .effect(.maskSource) = n.content { return false }
            if case .effect(.opacity(let value)) = n.content, value <= 0 { return false }
            current = n.parent
        }
        return true
    }
}
#endif
