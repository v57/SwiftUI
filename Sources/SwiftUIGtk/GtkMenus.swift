#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// A window's menu bar: the app's `.commands` in the standard menus (`WindowMenu.standardMenus`: File, Edit, View,
/// the app's own, Window, Help) as a `GtkMenuBar` above the content, shown only when the app declares commands.
/// Re-evaluated after each update and rebuilt when it changed. Keyboard shortcuts of its items work from the window's
/// key handler (Ctrl for ⌘); content that draws the menus itself (`windowMenuBarVisibility(.hidden)`) gets them as
/// `windowMenuBar` and the GTK bar steps aside.
@MainActor
final class GtkMenuBar {
    let widget: UnsafeMutablePointer<GtkWidget>
    private weak var controller: GtkWindowController?
    private var actions: [String: @MainActor () -> Void] = [:]
    private var shortcuts: [(KeyboardShortcut, String)] = []
    /// Item boxes passed to "activate" handlers (kept alive while their items exist).
    private var boxes: [Box] = []
    private var signature = ""
    private(set) var menus: [WindowMenu] = []
    private var nextID = 0
    /// Item ids by their title path ("File/New Window").
    private var paths: [String: String] = [:]
    /// Content draws the menus (`windowMenuBarVisibility(.hidden)`).
    var contentDrawsMenus = false { didSet { updateVisibility() } }

    final class Box {
        let id: String
        weak var bar: GtkMenuBar?
        init(id: String, bar: GtkMenuBar) {
            self.id = id
            self.bar = bar
        }
    }

    init(controller: GtkWindowController) {
        self.controller = controller
        widget = gtk_menu_bar_new()
        gtk_widget_set_no_show_all(widget, 1)
    }

    func refresh() {
        guard let controller else { return }
        let window = controller.window
        let newWindow: MenuItem = .button(title: "New Window", systemImage: nil, shortcut: KeyboardShortcut("n", modifiers: .command),
                                          isEnabled: true, isDestructive: false, action: { AppRuntime.openWindow?(nil, nil) })
        let close: MenuItem = .button(title: "Close Window", systemImage: nil, shortcut: KeyboardShortcut("w", modifiers: .command),
                                      isEnabled: true, isDestructive: false, action: { gtk_window_close(sui_window(raw(window))) })
        let hasWindowGroup = GtkAppRunner.scenes.contains { !$0.isSingle && $0.valueType == nil && $0.role == .main }
        let menus = WindowMenu.standardMenus(newWindow: hasWindowGroup ? newWindow : nil, closeWindow: close)
        // Actions and shortcuts are taken from the latest evaluation (their closures read current state).
        actions = [:]
        shortcuts = []
        paths = [:]
        nextID = 0
        var lines: [String] = []
        for menu in menus {
            lines.append("m|\(menu.title)")
            register(menu.items, path: [menu.title], into: &lines)
        }
        self.menus = menus
        let updated = lines.joined(separator: "\n")
        guard updated != signature else { return }
        signature = updated
        rebuild()
        // For content that draws the menu bar itself (`windowMenuBarVisibility(.hidden)`); only when the menus changed,
        // as setting it updates the content, which refreshes the menus.
        controller.host.graph.setEnvironment { $0.windowMenuBar = menus.isEmpty ? nil : menus }
    }

    /// Runs the enabled item with this shortcut.
    func perform(_ shortcut: KeyboardShortcut) -> Bool {
        guard let id = shortcuts.first(where: { $0.0 == shortcut })?.1, let action = actions[id] else { return false }
        action()
        return true
    }

    /// Runs the enabled item at a path of titles ("File", "New Window"); script mode's `menu`.
    func perform(path: [String]) -> Bool {
        guard let id = paths[path.joined(separator: "/")], let action = actions[id] else { return false }
        action()
        controller?.host.flushNow()
        return true
    }

    /// The menus as text, for script mode's dump.
    func dump() -> String {
        var out = ""
        for menu in menus {
            out += "Menu \"\(menu.title)\"\n"
            func visit(_ items: [MenuItem], depth: Int) {
                let indent = String(repeating: "  ", count: depth)
                for item in items {
                    switch item {
                    case let .button(title, _, shortcut, isEnabled, _, _):
                        out += indent + "MenuItem \"\(title)\"\(shortcut.map { " " + Self.describe($0) } ?? "")\(isEnabled ? "" : " disabled")\n"
                    case let .toggle(title, isOn, shortcut, isEnabled, _):
                        out += indent + "MenuToggle \"\(title)\" \(isOn ? "on" : "off")\(shortcut.map { " " + Self.describe($0) } ?? "")\(isEnabled ? "" : " disabled")\n"
                    case let .submenu(title, _, children):
                        out += indent + "Submenu \"\(title)\"\n"
                        visit(children, depth: depth + 1)
                    case let .section(title, children):
                        if let title, !title.isEmpty { out += indent + "Section \"\(title)\"\n" }
                        visit(children, depth: depth)
                    case .divider:
                        out += indent + "---\n"
                    case .label(let text):
                        out += indent + "Label \"\(text)\"\n"
                    }
                }
            }
            visit(menu.items, depth: 1)
        }
        return out
    }

    /// "Ctrl+Shift+S".
    static func describe(_ shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("Ctrl") }
        if shortcut.modifiers.contains(.control) { parts.append("Super") }
        if shortcut.modifiers.contains(.option) { parts.append("Alt") }
        if shortcut.modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(keyName(shortcut.key))
        return parts.joined(separator: "+")
    }

    private static func keyName(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "Enter"
        case .escape: "Esc"
        case .delete: "Backspace"
        case .deleteForward: "Del"
        case .tab: "Tab"
        case .space: "Space"
        case .upArrow: "Up"
        case .downArrow: "Down"
        case .leftArrow: "Left"
        case .rightArrow: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        default: String(key.character).uppercased()
        }
    }

    // MARK: Building

    private func register(_ items: [MenuItem], path: [String], into lines: inout [String]) {
        let depth = path.count
        for item in items {
            switch item {
            case let .button(title, _, shortcut, isEnabled, _, action):
                let id = add(action, shortcut: shortcut, enabled: isEnabled)
                paths[(path + [title]).joined(separator: "/")] = id
                lines.append("\(depth)|b|\(id)|\(title)|\(shortcut.map(Self.describe) ?? "")|\(isEnabled)")
            case let .toggle(title, isOn, shortcut, isEnabled, set):
                let id = add({ set(!isOn) }, shortcut: shortcut, enabled: isEnabled)
                paths[(path + [title]).joined(separator: "/")] = id
                lines.append("\(depth)|t|\(id)|\(title)|\(shortcut.map(Self.describe) ?? "")|\(isEnabled)|\(isOn)")
            case let .submenu(title, _, children):
                lines.append("\(depth)|s|\(title)")
                register(children, path: path + [title], into: &lines)
            case let .section(title, children):
                lines.append("\(depth)|-|\(title ?? "")")
                register(children, path: path, into: &lines)
            case .divider:
                lines.append("\(depth)|-")
            case .label(let text):
                lines.append("\(depth)|l|\(text)")
            }
        }
    }

    private func add(_ action: @escaping @MainActor () -> Void, shortcut: KeyboardShortcut?, enabled: Bool) -> String {
        nextID += 1
        let id = "i\(nextID)"
        if enabled {
            actions[id] = action
            if let shortcut { shortcuts.append((shortcut, id)) }
        }
        return id
    }

    private func rebuild() {
        let list = gtk_container_get_children(sui_container(raw(widget)))
        var item = list
        while let current = item {
            if let child = current.pointee.data { gtk_widget_destroy(child.assumingMemoryBound(to: GtkWidget.self)) }
            item = current.pointee.next
        }
        g_list_free(list)
        boxes = []
        var counter = 0
        for menu in menus {
            let top = gtk_menu_item_new_with_mnemonic("_" + menu.title)!
            let submenu = gtk_menu_new()!
            build(menu.items, into: submenu, counter: &counter)
            gtk_menu_item_set_submenu(sui_menu_item(raw(top)), submenu)
            gtk_menu_shell_append(sui_menu_shell(raw(widget)), top)
            gtk_widget_show_all(top)
        }
        updateVisibility()
    }

    private func build(_ items: [MenuItem], into menu: UnsafeMutablePointer<GtkWidget>, counter: inout Int) {
        func append(_ item: UnsafeMutablePointer<GtkWidget>) { gtk_menu_shell_append(sui_menu_shell(raw(menu)), item) }
        for item in items {
            switch item {
            case let .button(title, _, shortcut, isEnabled, _, _):
                counter += 1
                let widget = gtk_menu_item_new_with_label(title)!
                configure(widget, id: "i\(counter)", shortcut: shortcut, enabled: isEnabled)
                append(widget)
            case let .toggle(title, isOn, shortcut, isEnabled, _):
                counter += 1
                let widget = gtk_check_menu_item_new_with_label(title)!
                // Before the handler is connected: setting the state activates the item.
                gtk_check_menu_item_set_active(sui_check_menu_item(raw(widget)), isOn.gboolean)
                configure(widget, id: "i\(counter)", shortcut: shortcut, enabled: isEnabled)
                append(widget)
            case let .submenu(title, _, children):
                let widget = gtk_menu_item_new_with_label(title)!
                let submenu = gtk_menu_new()!
                build(children, into: submenu, counter: &counter)
                gtk_menu_item_set_submenu(sui_menu_item(raw(widget)), submenu)
                append(widget)
            case let .section(title, children):
                append(gtk_separator_menu_item_new())
                if let title, !title.isEmpty {
                    let label = gtk_menu_item_new_with_label(title)!
                    gtk_widget_set_sensitive(label, 0)
                    append(label)
                }
                build(children, into: menu, counter: &counter)
                append(gtk_separator_menu_item_new())
            case .divider:
                append(gtk_separator_menu_item_new())
            case .label(let text):
                let label = gtk_menu_item_new_with_label(text)!
                gtk_widget_set_sensitive(label, 0)
                append(label)
            }
        }
        // Separators doubled by sections next to dividers.
        var previousWasSeparator = true
        var last: UnsafeMutablePointer<GtkWidget>?
        let list = gtk_container_get_children(sui_container(raw(menu)))
        var node = list
        while let current = node {
            if let child = current.pointee.data?.assumingMemoryBound(to: GtkWidget.self) {
                let isSeparator = g_type_check_instance_is_a(UnsafeMutablePointer(OpaquePointer(child)), gtk_separator_menu_item_get_type()) != 0
                if isSeparator && previousWasSeparator { gtk_widget_destroy(child) } else { last = child; previousWasSeparator = isSeparator }
            }
            node = current.pointee.next
        }
        g_list_free(list)
        if let last, previousWasSeparator { gtk_widget_destroy(last) }
    }

    private func configure(_ widget: UnsafeMutablePointer<GtkWidget>, id: String, shortcut: KeyboardShortcut?, enabled: Bool) {
        gtk_widget_set_sensitive(widget, enabled.gboolean)
        if let shortcut, let label = gtk_bin_get_child(sui_bin(raw(widget))), let keyval = Self.keyval(shortcut.key) {
            gtk_accel_label_set_accel(sui_accel_label(raw(label)), keyval, Self.gdkModifiers(shortcut.modifiers))
        }
        let box = Box(id: id, bar: self)
        boxes.append(box)
        let activate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            MainActor.assumeIsolated {
                let box = object(data, as: Box.self)
                guard let bar = box.bar else { return }
                // After the menu closed (GTK is still in the menu's event handling).
                DispatchQueue.main.async {
                    bar.actions[box.id]?()
                    bar.controller?.host.flushNow()
                }
            }
        }
        connect(raw(widget), "activate", unretained(box), activate)
    }

    private func updateVisibility() {
        let visible = !menus.isEmpty && !contentDrawsMenus && controller?.showsMenuBarRow == true
        if visible { gtk_widget_show(widget) } else { gtk_widget_hide(widget) }
    }

    static func keyval(_ key: KeyEquivalent) -> guint? {
        switch key {
        case .return: guint(GDK_KEY_Return)
        case .escape: guint(GDK_KEY_Escape)
        case .delete: guint(GDK_KEY_BackSpace)
        case .deleteForward: guint(GDK_KEY_Delete)
        case .tab: guint(GDK_KEY_Tab)
        case .space: guint(GDK_KEY_space)
        case .upArrow: guint(GDK_KEY_Up)
        case .downArrow: guint(GDK_KEY_Down)
        case .leftArrow: guint(GDK_KEY_Left)
        case .rightArrow: guint(GDK_KEY_Right)
        case .home: guint(GDK_KEY_Home)
        case .end: guint(GDK_KEY_End)
        case .pageUp: guint(GDK_KEY_Page_Up)
        case .pageDown: guint(GDK_KEY_Page_Down)
        default: key.character.unicodeScalars.first.map { gdk_unicode_to_keyval($0.value) }
        }
    }

    static func gdkModifiers(_ modifiers: EventModifiers) -> GdkModifierType {
        var raw: guint = 0
        if modifiers.contains(.command) { raw |= GDK_CONTROL_MASK.rawValue }
        if modifiers.contains(.shift) { raw |= GDK_SHIFT_MASK.rawValue }
        if modifiers.contains(.option) { raw |= GDK_MOD1_MASK.rawValue }
        if modifiers.contains(.control) { raw |= GDK_SUPER_MASK.rawValue }
        return GdkModifierType(rawValue: raw)
    }
}
#endif
