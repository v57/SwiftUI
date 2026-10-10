#if os(Linux)
import Foundation
import CGtk3
import SwiftUI2Core

/// Runs an `App` with GTK 3: one `GtkWindow` (with a header bar for the title and toolbar) per
/// scene window, and `gtk_main` as the main loop.
@MainActor
public enum GtkAppRunner {
    static var scenes: [WindowDescription] = []
    static var controllers: [GtkWindowController] = []

    public static func install() {
        AppRuntime.runner = { windows in
            MainActor.assumeIsolated { run(windows) }
        }
    }

    static func run(_ windows: [WindowDescription]) -> Never {
        gtk_init(nil, nil)
        if let name = ProcessInfo.processInfo.environment["SWIFTUI2_GTK_DARK"] {
            sui_set_prefer_dark((name == "1").gboolean)
        }
        GtkText.install()
        GtkMainLoop.install()
        scenes = windows
        AppRuntime.openWindow = { id, value in open(id: id, value: value) }
        AppRuntime.dismissWindow = { id, value in
            for controller in controllers where (id == nil || controller.description.id == id) && (value == nil || controller.value == value) {
                controller.close()
            }
        }
        for description in windows where description.opensAtLaunch {
            controllers.append(GtkWindowController(description: description, value: nil))
        }
        if controllers.isEmpty, let first = windows.first {
            controllers.append(GtkWindowController(description: first, value: nil))
        }
        GtkMainLoop.serviceTimers()
        gtk_main()
        exit(0)
    }

    static func open(id: String?, value: AnyHashable?) {
        let candidates = scenes.filter { scene in
            if let id { return scene.id == id }
            if let value, let type = scene.valueType { return Swift.type(of: value.base) == type }
            return scene.opensAtLaunch
        }
        guard let description = candidates.first else {
            FileHandle.standardError.write(Data("SwiftUI2: no window for openWindow(id: \(id ?? "nil"))\n".utf8))
            return
        }
        // Single windows and windows already showing a value are brought to the front.
        if let existing = controllers.first(where: { $0.description.id == description.id && (description.isSingle || (value != nil && $0.value == value)) }) {
            gtk_window_present(sui_window(raw(existing.window)))
            return
        }
        controllers.append(GtkWindowController(description: description, value: value))
    }

    static func closed(_ controller: GtkWindowController) {
        controllers.removeAll { $0 === controller }
        if controllers.isEmpty { gtk_main_quit() }
    }
}

/// One scene window: a `GtkWindow` with a `GtkHeaderBar` (title, toolbar items) and a host.
@MainActor
final class GtkWindowController {
    let description: WindowDescription
    let value: AnyHashable?
    let window: UnsafeMutablePointer<GtkWidget>
    let headerBar: UnsafeMutablePointer<GtkWidget>
    let host: GtkHost
    private var toolbarItems: [String: ToolbarItem] = [:]
    private var title: String

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

    init(description: WindowDescription, value: AnyHashable?) {
        self.description = description
        self.value = value
        title = description.title
        window = gtk_window_new(GTK_WINDOW_TOPLEVEL)
        headerBar = gtk_header_bar_new()
        gtk_header_bar_set_show_close_button(sui_header_bar(raw(headerBar)), 1)
        gtk_header_bar_set_title(sui_header_bar(raw(headerBar)), description.title)
        gtk_window_set_titlebar(sui_window(raw(window)), headerBar)
        host = GtkHost { backend in description.makeGraphForValue(backend, value) }
        gtk_container_add(sui_container(raw(window)), host.widget)
        // Like SwiftUI (and the AppKit runner): the content's minimum size bounds the window; the
        // default size is `defaultSize`, else the ideal size for panels and content-sized windows,
        // else 900x450 grown to the minimum.
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
        host.graph.onNavigationTitleChange = { [weak self] title in self?.setTitle(title) }
        host.graph.onNavigationSubtitleChange = { [weak self] subtitle in
            guard let self else { return }
            gtk_header_bar_set_subtitle(sui_header_bar(raw(self.headerBar)), subtitle)
        }
        host.graph.onToolbarChange = { [weak self] toolbar in self?.updateToolbar(toolbar) }
        connectSignals()
        gtk_widget_show_all(window)
    }

    private func connectSignals() {
        let data = unretained(self)
        let destroy: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            MainActor.assumeIsolated {
                let controller = object(data, as: GtkWindowController.self)
                controller.host.tearDown()
                for item in controller.toolbarItems.values { item.host?.tearDown() }
                GtkAppRunner.closed(controller)
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
    }

    func close() {
        gtk_window_close(sui_window(raw(window)))
    }

    private func setTitle(_ title: String?) {
        self.title = title ?? description.title
        gtk_header_bar_set_title(sui_header_bar(raw(headerBar)), self.title)
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
        for entry in toolbar.items where !entry.isSidebarItem {
            keep.insert(entry.id)
            let item: ToolbarItem
            if let button = entry.button {
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
                // Other content (search fields, pickers, custom views) is hosted by SwiftUI2.
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
