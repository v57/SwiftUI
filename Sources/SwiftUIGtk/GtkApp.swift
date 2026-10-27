#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Runs an `App` with GTK 3: one `GtkWindow` (with a header bar for the title and toolbar, and a
/// menu bar for the app's commands) per scene window, and `gtk_main` as the main loop.
@MainActor
public enum GtkAppRunner {
    static var scenes: [WindowDescription] = []
    static var controllers: [GtkWindowController] = []
    /// The appearance GTK had at launch (restored when no window asks for one).
    private static var systemPrefersDark: Bool?

    public static func install() {
        AppRuntime.runner = { windows in
            MainActor.assumeIsolated { run(windows) }
        }
    }

    static func run(_ windows: [WindowDescription]) -> Never {
        gtk_init(nil, nil)
        if let name = ProcessInfo.processInfo.environment["SWIFTUI_GTK_DARK"] {
            sui_set_prefer_dark((name == "1").gboolean)
        } else {
            followDesktopColorScheme()
        }
        systemPrefersDark = sui_prefers_dark() != 0
        GtkText.install()
        GtkMainLoop.install()
        scenes = windows
        AppRuntime.openWindow = { id, value in open(id: id, value: value) }
        AppRuntime.openSettings = { openSettings() }
        AppRuntime.dismissWindow = { id, value in
            for controller in controllers where (id == nil || controller.description.id == id) && (value == nil || controller.value == value) {
                controller.close()
            }
        }
        AppRuntime.presentWindow = { description, onClose in
            let controller = GtkWindowController(description: description, value: nil)
            controller.onClose = onClose
            add(controller)
            return controller
        }
        AppRuntime.focusPresentedWindow = { token in
            guard let controller = token as? GtkWindowController else { return }
            gtk_window_present(sui_window(raw(controller.window)))
        }
        AppRuntime.closePresentedWindow = { token in (token as? GtkWindowController)?.close() }
        AppRuntime.performWindowDrag = {
            controllers.first { gtk_window_is_active(sui_window(raw($0.window))) != 0 }?.beginMoveDrag()
        }
        DefaultsSaver.start()
        // Like SwiftUI, the first window scene opens at launch, plus scenes presented at launch (a welcome window
        // in place of a suppressed main one); with neither, the first scene.
        let first = windows.firstIndex(where: \.opensAtLaunch)
        let presented = windows.indices.filter { windows[$0].launchBehavior == .presented && $0 != first }
        if let index = first ?? (presented.isEmpty && !windows.isEmpty ? 0 : nil) {
            add(GtkWindowController(description: windows[index], value: nil))
        }
        for index in presented { add(GtkWindowController(description: windows[index], value: nil)) }
        GtkMainLoop.serviceTimers()
        openLaunchFiles()
        GtkScript.startIfRequested()
        gtk_main()
        UserDefaults.standard.synchronize()
        exit(0)
    }

    /// Files and folders on the command line (`app <path>…`, or file URLs as a .desktop file's `%U` passes them) go to the
    /// windows' `onOpenURL` handlers once they are up, as the Mac's open events do. Options (`-name`, `--name`) and
    /// the argument after one are not paths.
    static func openLaunchFiles() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let urls = arguments.indices.compactMap { index -> URL? in
            let argument = arguments[index]
            guard !argument.hasPrefix("-"), index == 0 || !arguments[index - 1].hasPrefix("-") else { return nil }
            if argument.hasPrefix("file://") { return URL(string: argument) }
            guard FileManager.default.fileExists(atPath: argument) else { return nil }
            return URL(fileURLWithPath: argument).standardizedFileURL
        }
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { AppRuntime.handleOpenURLs(urls) }
    }

    static func open(id: String?, value: AnyHashable?) {
        let candidates = scenes.filter { scene in
            if let id { return scene.id == id }
            if let value, let type = scene.valueType { return Swift.type(of: value.base) == type }
            return scene.opensAtLaunch
        }
        guard let description = candidates.first else {
            FileHandle.standardError.write(Data("SwiftUI: no window for openWindow(id: \(id ?? "nil"))\n".utf8))
            return
        }
        // Single windows and windows already showing a value are brought to the front.
        if let existing = controllers.first(where: { $0.description.id == description.id && (description.isSingle || (value != nil && $0.value == value)) }) {
            gtk_window_present(sui_window(raw(existing.window)))
            return
        }
        add(GtkWindowController(description: description, value: value))
    }

    /// The `Settings` scene's window (`openSettings`, SettingsLink, Edit ▸ Preferences…): one, brought to the front.
    static func openSettings() {
        guard let description = scenes.first(where: { $0.role == .settings }) else { return }
        if let existing = controllers.first(where: { $0.description.role == .settings }) {
            gtk_window_present(sui_window(raw(existing.window)))
            return
        }
        add(GtkWindowController(description: description, value: nil))
    }

    static func closed(_ controller: GtkWindowController) {
        controllers.removeAll { $0 === controller }
        UserDefaults.standard.synchronize()
        if controllers.isEmpty { gtk_main_quit() }
    }

    /// The desktop's Dark style (`color-scheme`, which GTK 3 itself ignores) asks for GTK's dark theme, at launch and
    /// when it changes (Ubuntu also switches the theme to Yaru-dark; GNOME and Fedora only set color-scheme).
    private static func followDesktopColorScheme() {
        guard sui_color_scheme_dark() >= 0, let interface = sui_interface_settings() else { return }
        let themeIsDark = sui_prefers_dark() != 0
        if sui_color_scheme_dark() == 1, !themeIsDark { sui_set_prefer_dark(1) }
        let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<gchar>?, UnsafeMutableRawPointer?) -> Void = { _, _, _ in
            MainActor.assumeIsolated {
                let dark = sui_color_scheme_dark() == 1 || GtkAppRunner.themeIsDark
                GtkAppRunner.systemPrefersDark = dark
                GtkAppRunner.updatePreferredColorScheme()
            }
        }
        self.themeIsDark = themeIsDark
        _ = connect(UnsafeMutableRawPointer(interface), "changed::color-scheme", nil, changed)
    }

    /// Whether the GTK theme itself is dark (`Yaru-dark`) or asks for it, before the desktop's style was applied.
    private static var themeIsDark = false

    /// A new window: its content's first update (in its init) asked for its color scheme before it was listed.
    private static func add(_ controller: GtkWindowController) {
        controllers.append(controller)
        updatePreferredColorScheme()
    }

    /// GTK's dark preference is the screen's, not a window's: the windows' `preferredColorScheme` (the newest
    /// window that asks wins) sets it, and with none the launch appearance comes back.
    static func updatePreferredColorScheme() {
        let wanted = controllers.reversed().lazy.compactMap(\.preferredColorScheme).first
        let dark = wanted.map { $0 == .dark } ?? systemPrefersDark ?? false
        if (sui_prefers_dark() != 0) != dark { sui_set_prefer_dark(dark.gboolean) }
    }
}

/// Saves the defaults every couple of seconds: swift-corelibs-foundation writes them only on `synchronize()`.
@MainActor
enum DefaultsSaver {
    private static var timer: DispatchSourceTimer?

    static func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { UserDefaults.standard.synchronize() }
        timer.resume()
        self.timer = timer
    }
}

/// One scene window: a `GtkWindow` with a `GtkHeaderBar` (title, toolbar items), a menu bar and a host.
///
/// Content that runs up into the title bar (a hidden title bar, or `toolbarBackgroundVisibility(.hidden, for:
/// .windowToolbar)`, as the kits' own bars do) gets the whole window: the header bar then floats over the content's
/// top trailing corner without a background or title, with the toolbar and the window's buttons, and the content
/// learns where it is from `windowTitleBarArea`; the rest of that row drags the window.
@MainActor
final class GtkWindowController {
    let description: WindowDescription
    let value: AnyHashable?
    let window: UnsafeMutablePointer<GtkWidget>
    let headerBar: UnsafeMutablePointer<GtkWidget>
    /// The header bar's event box while it floats over the content (it drags the window).
    private let floatingBar: UnsafeMutablePointer<GtkWidget>
    /// The window's titlebar while the content runs up into it: an empty, hidden widget (the window keeps its
    /// client-side decorations).
    private let emptyTitlebar: UnsafeMutablePointer<GtkWidget>
    private let overlay: UnsafeMutablePointer<GtkWidget>
    let host: GtkHost
    private(set) lazy var menuBar = GtkMenuBar(controller: self)
    private var toolbarItems: [String: ToolbarItem] = [:]
    private var toolbarActions: [String: @MainActor () -> Void] = [:]
    private var title: String
    /// Called once the window closed (windows presented from code).
    var onClose: (@MainActor () -> Void)?
    /// `preferredColorScheme` of the content.
    private(set) var preferredColorScheme: ColorScheme?
    private var hiddenTitleBar: Bool
    private var toolbarBackgroundHidden = false
    private var hidesTitle = false
    private var barProvider: UnsafeMutablePointer<GtkCssProvider>?

    final class ToolbarItem {
        let widget: UnsafeMutablePointer<GtkWidget>
        var action: (@MainActor () -> Void)?
        var host: GtkHost?
        var signature: String
        init(widget: UnsafeMutablePointer<GtkWidget>, signature: String) {
            self.widget = widget
            self.signature = signature
        }
    }

    /// The window's title as shown (the navigation title, else the scene's).
    var currentTitle: String { title }

    /// A plain window has no menu bar row (the Mac's menus are the app's, not the window's).
    var showsMenuBarRow: Bool { description.kind != .plain && description.kind != .hiddenTitleBar }

    init(description: WindowDescription, value: AnyHashable?) {
        self.description = description
        self.value = value
        title = description.title
        hiddenTitleBar = description.kind == .hiddenTitleBar
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        gtk_window_set_title(sui_window(raw(window)), description.title)
        headerBar = gtk_header_bar_new()
        gtk_header_bar_set_show_close_button(sui_header_bar(raw(headerBar)), 1)
        gtk_header_bar_set_title(sui_header_bar(raw(headerBar)), description.title)
        floatingBar = gtk_event_box_new()
        gtk_widget_set_halign(floatingBar, GTK_ALIGN_END)
        gtk_widget_set_valign(floatingBar, GTK_ALIGN_START)
        gtk_widget_set_no_show_all(floatingBar, 1)
        g_object_ref_sink(UnsafeMutableRawPointer(floatingBar))
        emptyTitlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        g_object_ref_sink(UnsafeMutableRawPointer(emptyTitlebar))
        g_object_ref_sink(UnsafeMutableRawPointer(headerBar))
        gtk_window_set_titlebar(sui_window(raw(window)), headerBar)
        host = GtkHost { backend in description.makeGraphForValue(backend, value) }
        overlay = gtk_overlay_new()
        let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_pack_start(sui_box(raw(column)), menuBar.widget, 0, 0, 0)
        gtk_box_pack_start(sui_box(raw(column)), host.widget, 1, 1, 0)
        gtk_container_add(sui_container(raw(overlay)), column)
        gtk_overlay_add_overlay(sui_overlay(raw(overlay)), floatingBar)
        gtk_container_add(sui_container(raw(window)), overlay)
        host.graph.setEnvironment { [window] environment in
            // dismissWindow() closes this window.
            environment.dismissWindow = DismissWindowAction(_current: { gtk_window_close(sui_window(raw(window))) })
        }
        host.menuShortcut = { [weak self] shortcut in self?.menuBar.perform(shortcut) ?? false }
        host.titleBarDrag = { [weak self] event in self?.titleBarPress(event) ?? false }
        host.titleBarDragHeight = { [weak self] in self?.titleBarDragHeight ?? 0 }
        host.onDidUpdate = { [weak self] in self?.menuBar.refresh() }
        host.graph.onNavigationTitleChange = { [weak self] title in self?.setTitle(title) }
        host.graph.onNavigationSubtitleChange = { [weak self] subtitle in
            guard let self else { return }
            gtk_header_bar_set_subtitle(sui_header_bar(raw(self.headerBar)), subtitle)
        }
        host.graph.onToolbarChange = { [weak self] toolbar in
            self?.updateToolbar(toolbar)
            self?.hidesTitle = toolbar.chrome.removesTitle
            self?.updateTitleBar()
        }
        host.graph.onWindowConfigurationChange = { [weak self] configuration in
            guard let self else { return }
            toolbarBackgroundHidden = configuration.isToolbarBackgroundHidden == true
            menuBar.contentDrawsMenus = configuration.isMenuBarHidden == true
            if preferredColorScheme != configuration.preferredColorScheme {
                preferredColorScheme = configuration.preferredColorScheme
                GtkAppRunner.updatePreferredColorScheme()
            }
            updateTitleBar()
        }
        menuBar.refresh()
        updateTitleBar()
        sizeWindow()
        connectSignals()
        gtk_widget_show_all(window)
    }

    /// Like SwiftUI (and the AppKit runner): the content's minimum size bounds the window; the default size is
    /// `defaultSize`, else the ideal size for panels and content-sized windows, else 900x450 grown to the minimum.
    private func sizeWindow() {
        let minimum = host.sizeThatFits(ProposedViewSize(width: 0, height: 0))
        gtk_widget_set_size_request(host.widget, Int32(min(minimum.width, 4000).rounded(.up)), Int32(min(minimum.height, 4000).rounded(.up)))
        let size: CGSize
        if let defaultSize = description.defaultSize {
            size = defaultSize
        } else if description.kind == .utility || description.resizability == .contentSize {
            size = host.sizeThatFits(.unspecified)
        } else {
            size = CGSize(width: max(minimum.width, 900), height: max(minimum.height, 450))
        }
        gtk_window_set_default_size(sui_window(raw(window)), Int32(size.width.rounded()), Int32(size.height.rounded()))
        gtk_window_set_position(sui_window(raw(window)), GTK_WIN_POS_CENTER)
        if description.resizability == .contentSize {
            let maximum = host.sizeThatFits(ProposedViewSize(width: .infinity, height: .infinity))
            if maximum.width.isFinite, maximum.height.isFinite, maximum.width <= minimum.width + 0.5, maximum.height <= minimum.height + 0.5 {
                gtk_window_set_resizable(sui_window(raw(window)), 0)
            }
        }
    }

    private func connectSignals() {
        let data = unretained(self)
        let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            MainActor.assumeIsolated {
                let controller = object(data, as: GtkWindowController.self)
                controller.host.tearDown()
                for item in controller.toolbarItems.values { item.host?.tearDown() }
                controller.onClose?()
                controller.onClose = nil
                GtkAppRunner.closed(controller)
                GtkAppRunner.updatePreferredColorScheme()
            }
        }
        connect(raw(window), "destroy", data, destroy)
        // Keys reach the content first unless a native widget (an entry) has focus.
        let key: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkWindowController.self).host.keyEvent(event.pointee) }.gboolean
        }
        connect(raw(window), "key-press-event", data, key)
        let focus: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            MainActor.assumeIsolated {
                let controller = object(data, as: GtkWindowController.self)
                let active = gtk_window_is_active(sui_window(raw(controller.window))) != 0
                controller.host.graph.setEnvironment { $0.appearsActive = active }
                controller.host.flushNow()
            }
        }
        connect(raw(window), "notify::is-active", data, focus)
        // The floating header bar: its size is the title bar row's, and presses on its empty part drag the window.
        let allocate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkRectangle>?, UnsafeMutableRawPointer?) -> Void = { _, rect, data in
            guard let rect else { return }
            MainActor.assumeIsolated {
                object(data, as: GtkWindowController.self).floatingBarAllocated(CGSize(width: CGFloat(rect.pointee.width), height: CGFloat(rect.pointee.height)))
            }
        }
        connect(raw(floatingBar), "size-allocate", data, allocate)
        let press: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventButton>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkWindowController.self).titleBarPress(event.pointee) }.gboolean
        }
        connect(raw(floatingBar), "button-press-event", data, press)
    }

    func close() {
        gtk_window_close(sui_window(raw(window)))
    }

    private func setTitle(_ title: String?) {
        self.title = title ?? description.title
        gtk_window_set_title(sui_window(raw(window)), self.title)
        updateTitleBar()
    }

    /// Escape or Back: dismisses the top presentation (sheet, alert, ...), else pops the navigation stack.
    func back() -> Bool {
        var handled = host.graph.dismissTopPresentation()
        if !handled, let pop = toolbarActions["navigation.back"] {
            pop()
            handled = true
        }
        host.flushNow()
        return handled
    }

    // MARK: Title bar

    /// The content runs up into the title bar: a hidden title bar, or the window toolbar's background hidden.
    private var contentInTitleBar: Bool { hiddenTitleBar || toolbarBackgroundHidden }
    private var titleBarState: (Bool, Bool)?
    private var titleBarArea = WindowTitleBarArea(height: 0, leading: 0, trailing: 0)
    private var lastPress: (button: guint, x: Double, y: Double, time: guint32)?

    private func updateTitleBar() {
        let bar = sui_header_bar(raw(headerBar))
        let floating = contentInTitleBar
        gtk_header_bar_set_title(bar, floating || hidesTitle ? nil : title)
        guard titleBarState.map({ $0 != (floating, hidesTitle) }) ?? true else { return }
        let wasFloating = titleBarState?.0 ?? false
        titleBarState = (floating, hidesTitle)
        if floating != wasFloating {
            if floating {
                gtk_window_set_titlebar(sui_window(raw(window)), emptyTitlebar)
                gtk_widget_hide(emptyTitlebar)
                gtk_container_add(sui_container(raw(floatingBar)), headerBar)
                setFloatingStyle(true)
                gtk_widget_show_all(headerBar)
                gtk_widget_show(floatingBar)
            } else {
                gtk_widget_hide(floatingBar)
                gtk_container_remove(sui_container(raw(floatingBar)), headerBar)
                setFloatingStyle(false)
                gtk_window_set_titlebar(sui_window(raw(window)), headerBar)
                gtk_widget_show_all(headerBar)
            }
        }
        let area = floating ? titleBarArea : nil
        host.graph.setEnvironment { $0.windowTitleBarArea = area }
    }

    /// Without a background, title or bottom border while it floats over the content.
    private func setFloatingStyle(_ floating: Bool) {
        let context = gtk_widget_get_style_context(headerBar)
        if floating {
            if barProvider == nil {
                barProvider = gtk_css_provider_new()
                gtk_css_provider_load_from_data(barProvider, "headerbar { background: none; border: none; box-shadow: none; }", -1, nil)
            }
            gtk_style_context_add_provider(context, OpaquePointer(barProvider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
            gtk_style_context_remove_class(context, "titlebar")
        } else if let barProvider {
            gtk_style_context_remove_provider(context, OpaquePointer(barProvider))
            gtk_style_context_add_class(context, "titlebar")
        }
    }

    private func floatingBarAllocated(_ size: CGSize) {
        let area = WindowTitleBarArea(height: size.height, leading: 0, trailing: size.width)
        guard area != titleBarArea else { return }
        titleBarArea = area
        guard contentInTitleBar else { return }
        host.graph.setEnvironment { $0.windowTitleBarArea = area }
        host.flushSoon()
    }

    /// A press nothing else took in the title bar row (the floating bar's empty part, or content in the row): drags
    /// the window; a double click maximizes or restores it.
    func titleBarPress(_ event: GdkEventButton) -> Bool {
        guard contentInTitleBar, event.button == 1 else { return false }
        if event.type == GDK_2BUTTON_PRESS {
            if gtk_window_is_maximized(sui_window(raw(window))) != 0 {
                gtk_window_unmaximize(sui_window(raw(window)))
            } else {
                gtk_window_maximize(sui_window(raw(window)))
            }
            return true
        }
        guard event.type == GDK_BUTTON_PRESS else { return false }
        gtk_window_begin_move_drag(sui_window(raw(window)), Int32(event.button), Int32(event.x_root), Int32(event.y_root), event.time)
        return true
    }

    /// The height of the row content may drag the window from (zero unless the content runs up into it).
    var titleBarDragHeight: CGFloat { contentInTitleBar ? titleBarArea.height : 0 }

    /// `WindowDragGesture` and `performWindowDrag`: starts moving the window with the current press.
    func beginMoveDrag() {
        guard let event = gtk_get_current_event() else { return }
        defer { gdk_event_free(event) }
        var x = 0.0, y = 0.0
        gdk_event_get_root_coords(event, &x, &y)
        gtk_window_begin_move_drag(sui_window(raw(window)), 1, Int32(x), Int32(y), gdk_event_get_time(event))
    }

    /// The window's frame (its allocation without the client-side decorations' shadow margins), in the toplevel's
    /// coordinates: what screenshots show.
    var visibleFrame: CGRect {
        var rects: [GtkAllocation] = []
        var allocation = GtkAllocation()
        if !contentInTitleBar, gtk_widget_get_visible(headerBar) != 0 {
            gtk_widget_get_allocation(headerBar, &allocation)
            rects.append(allocation)
        }
        gtk_widget_get_allocation(overlay, &allocation)
        rects.append(allocation)
        let minX = rects.map(\.x).min()!, minY = rects.map(\.y).min()!
        let maxX = rects.map { $0.x + $0.width }.max()!, maxY = rects.map { $0.y + $0.height }.max()!
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // MARK: Toolbar

    /// Leading placements go to the start of the header bar, the rest to the end.
    private static func isLeading(_ placement: ToolbarItemPlacement) -> Bool {
        switch placement {
        case .navigation, .cancellationAction, .topBarLeading: true
        default: false
        }
    }

    private func updateToolbar(_ toolbar: WindowToolbar) {
        var keep: Set<String> = []
        var start: [UnsafeMutablePointer<GtkWidget>] = []
        var end: [UnsafeMutablePointer<GtkWidget>] = []
        var actions: [String: @MainActor () -> Void] = [:]
        for entry in toolbar.items where !entry.isSidebarItem {
            keep.insert(entry.id)
            let item: ToolbarItem
            if let button = entry.button {
                actions[entry.id] = button.action
                let signature = "button|\(button.title ?? "")|\(button.systemImage ?? "")|\(entry.placement)"
                if let existing = toolbarItems[entry.id], existing.signature == signature {
                    item = existing
                } else {
                    toolbarItems[entry.id].map(remove)
                    item = makeButton(entry, button, signature: signature)
                    toolbarItems[entry.id] = item
                }
                item.action = button.action
                gtk_widget_set_sensitive(item.widget, button.isEnabled.gboolean)
                gtk_widget_set_tooltip_text(item.widget, button.help ?? button.title)
            } else {
                // Other content (search fields, pickers, custom views) is hosted by SwiftUI.
                if let existing = toolbarItems[entry.id], let itemHost = existing.host {
                    item = existing
                    itemHost.graph.setRootView(entry.content)
                    itemHost.flushNow()
                } else {
                    toolbarItems[entry.id].map(remove)
                    item = makeHostedItem(entry)
                    toolbarItems[entry.id] = item
                }
                let size = item.host!.sizeThatFits(.unspecified)
                gtk_widget_set_size_request(item.widget, Int32(min(max(size.width, 24), 360).rounded(.up)), Int32(max(size.height, 24).rounded(.up)))
            }
            if Self.isLeading(entry.placement) { start.append(item.widget) } else { end.append(item.widget) }
        }
        toolbarActions = actions
        for (id, item) in toolbarItems where !keep.contains(id) {
            remove(item)
            toolbarItems[id] = nil
        }
        // Re-pack in order (end items are packed right to left); packed widgets are kept alive
        // across the removal by a temporary reference.
        let bar = sui_header_bar(raw(headerBar))
        var repacked: [UnsafeMutablePointer<GtkWidget>] = []
        for widget in start + end where gtk_widget_get_parent(widget) != nil {
            g_object_ref(UnsafeMutableRawPointer(widget))
            gtk_container_remove(sui_container(raw(headerBar)), widget)
            repacked.append(widget)
        }
        for widget in start { gtk_header_bar_pack_start(bar, widget) }
        for widget in end.reversed() { gtk_header_bar_pack_end(bar, widget) }
        for widget in repacked { g_object_unref(UnsafeMutableRawPointer(widget)) }
        gtk_widget_show_all(headerBar)
    }

    private func remove(_ item: ToolbarItem) {
        item.host?.tearDown()
        gtk_widget_destroy(item.widget)
    }

    private func makeButton(_ entry: ToolbarEntry, _ button: ToolbarButton, signature: String) -> ToolbarItem {
        let widget: UnsafeMutablePointer<GtkWidget>
        if entry.id == "navigation.back" {
            widget = gtk_button_new_from_icon_name("go-previous-symbolic", GTK_ICON_SIZE_BUTTON)
        } else if let symbol = button.systemImage {
            widget = gtk_button_new()
            if let icon = Self.iconName(forSymbol: symbol) {
                gtk_button_set_image(sui_button(raw(widget)), gtk_image_new_from_icon_name(icon, GTK_ICON_SIZE_BUTTON))
            } else if GtkText.hasSymbolFont {
                let label = gtk_label_new(nil)!
                let glyph = SymbolFont.glyph(forSystemName: symbol)
                gtk_label_set_markup(UnsafeMutablePointer(OpaquePointer(label)), "<span font_family=\"\(GtkText.symbolFamily)\" size=\"\(Int(GtkText.bodySize * 1.3 * 1024))\">\(glyph.text)</span>")
                gtk_container_add(sui_container(raw(widget)), label)
            } else {
                gtk_button_set_label(sui_button(raw(widget)), button.title ?? symbol)
            }
        } else {
            widget = gtk_button_new_with_label(button.title ?? "")
        }
        if entry.placement == .confirmationAction {
            gtk_style_context_add_class(gtk_widget_get_style_context(widget), "suggested-action")
        }
        if button.isDestructive {
            gtk_style_context_add_class(gtk_widget_get_style_context(widget), "destructive-action")
        }
        let item = ToolbarItem(widget: widget, signature: signature)
        let clicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            MainActor.assumeIsolated {
                let item = object(data, as: ToolbarItem.self)
                item.action?()
                for controller in GtkAppRunner.controllers where controller.toolbarItems.values.contains(where: { $0 === item }) {
                    controller.host.flushNow()
                }
            }
        }
        connect(raw(widget), "clicked", unretained(item), clicked)
        return item
    }

    private func makeHostedItem(_ entry: ToolbarEntry) -> ToolbarItem {
        let itemHost = GtkHost { backend in ViewGraph(rootView: entry.content, backend: backend, environment: entry.environment) }
        itemHost.drawsBackground = false
        gtk_widget_set_valign(itemHost.widget, GTK_ALIGN_CENTER)
        let item = ToolbarItem(widget: itemHost.widget, signature: "hosted")
        item.host = itemHost
        return item
    }

    /// Freedesktop symbolic icons for common toolbar symbols (others use the symbol font).
    static func iconName(forSymbol symbol: String) -> String? {
        let table: [String: String] = [
            "plus": "list-add-symbolic", "minus": "list-remove-symbolic", "trash": "user-trash-symbolic",
            "gear": "emblem-system-symbolic", "gearshape": "emblem-system-symbolic", "magnifyingglass": "system-search-symbolic",
            "square.and.arrow.up": "document-send-symbolic", "square.and.arrow.down": "document-save-symbolic",
            "chevron.left": "go-previous-symbolic", "chevron.right": "go-next-symbolic", "arrow.clockwise": "view-refresh-symbolic",
            "xmark": "window-close-symbolic", "checkmark": "object-select-symbolic", "pencil": "document-edit-symbolic",
            "square.and.pencil": "document-edit-symbolic", "folder": "folder-symbolic", "doc": "text-x-generic-symbolic",
            "sidebar.left": "view-sidebar-start-symbolic", "line.3.horizontal": "open-menu-symbolic", "ellipsis.circle": "view-more-symbolic",
            "ellipsis": "view-more-symbolic", "star": "starred-symbolic", "info.circle": "dialog-information-symbolic",
            "heart": "emblem-favorite-symbolic", "house": "go-home-symbolic", "play.fill": "media-playback-start-symbolic",
            "pause.fill": "media-playback-pause-symbolic", "stop.fill": "media-playback-stop-symbolic",
        ]
        return table[symbol]
    }
}
#endif
