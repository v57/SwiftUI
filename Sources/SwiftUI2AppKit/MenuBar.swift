#if canImport(AppKit)
import AppKit
import SwiftUI2Core

/// The main menu: the standard macOS SwiftUI menus plus the app's `.commands`. Command content is
/// re-evaluated whenever a menu updates (opening it or matching a key equivalent), so it always
/// reflects current state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let appName: String
    let hasSettings: Bool
    let hasWindowGroup: Bool
    weak var settingsTarget: AnyObject?
    /// Top-level menu → builder of its items.
    private var builders: [ObjectIdentifier: () -> [NSMenuItem]] = [:]
    /// Keeps menu actions alive.
    private var actions: [MenuAction] = []

    init(appName: String, hasSettings: Bool, hasWindowGroup: Bool, settingsTarget: AnyObject?) {
        self.appName = appName
        self.hasSettings = hasSettings
        self.hasWindowGroup = hasWindowGroup
        self.settingsTarget = settingsTarget
    }

    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        add(to: main, title: appName) { [unowned self] in self.appMenuItems() }
        add(to: main, title: "File") { [unowned self] in self.fileMenuItems() }
        add(to: main, title: "Edit") { [unowned self] in self.editMenuItems() }
        // Custom menus (CommandMenu) go between Edit/View and Window, in declaration order.
        add(to: main, title: "View") { [unowned self] in self.viewMenuItems() }
        var titles: [String] = []
        for case .menu(let title, _) in AppRuntime.commandEntries() where !titles.contains(title) { titles.append(title) }
        for title in titles {
            add(to: main, title: title) { [unowned self] in self.customMenuItems(title) }
        }
        let window = add(to: main, title: "Window") { [unowned self] in self.windowMenuItems() }
        NSApplication.shared.windowsMenu = window
        let help = add(to: main, title: "Help") { [unowned self] in self.groupItems(.help, standard: []) }
        NSApplication.shared.helpMenu = help
        return main
    }

    @discardableResult
    private func add(to main: NSMenu, title: String, items: @escaping () -> [NSMenuItem]) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.delegate = self
        menu.autoenablesItems = true
        builders[ObjectIdentifier(menu)] = items
        item.submenu = menu
        main.addItem(item)
        populate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    private func populate(_ menu: NSMenu) {
        guard let build = builders[ObjectIdentifier(menu)] else { return }
        let items = build()
        menu.removeAllItems()
        for item in items { menu.addItem(item) }
    }

    // MARK: Standard menus

    private func standard(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func appMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += groupItems(.appInfo, standard: [standard("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))])
        items.append(.separator())
        if hasSettings {
            items += groupItems(.appSettings, standard: [standard("Settings…", Selector(("showSettings:")), ",", target: settingsTarget)])
            items.append(.separator())
        } else {
            items += groupItems(.appSettings, standard: [])
        }
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApplication.shared.servicesMenu = servicesMenu
        items += groupItems(.systemServices, standard: [services])
        items.append(.separator())
        items += groupItems(.appVisibility, standard: [
            standard("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        ])
        items.append(.separator())
        items += groupItems(.appTermination, standard: [standard("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")])
        return tidy(items)
    }

    private func fileMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += groupItems(.newItem, standard: hasWindowGroup ? [standard("New Window", Selector(("newWindow:")), "n", target: settingsTarget)] : [])
        items.append(.separator())
        items.append(standard("Close", #selector(NSWindow.performClose(_:)), "w"))
        items += groupItems(.saveItem, standard: [])
        items.append(.separator())
        items += groupItems(.importExport, standard: [])
        items.append(.separator())
        items += groupItems(.printItem, standard: [])
        return tidy(items)
    }

    private func editMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += groupItems(.undoRedo, standard: [
            standard("Undo", Selector(("undo:")), "z"),
            standard("Redo", Selector(("redo:")), "z", [.command, .shift]),
        ])
        items.append(.separator())
        items += groupItems(.pasteboard, standard: [
            standard("Cut", #selector(NSText.cut(_:)), "x"),
            standard("Copy", #selector(NSText.copy(_:)), "c"),
            standard("Paste", #selector(NSText.paste(_:)), "v"),
            standard("Delete", #selector(NSText.delete(_:))),
            standard("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        items.append(.separator())
        items += groupItems(.textEditing, standard: [])
        items += groupItems(.textFormatting, standard: [])
        return tidy(items)
    }

    private func viewMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += groupItems(.toolbar, standard: [])
        items += groupItems(.sidebar, standard: [])
        items.append(.separator())
        items.append(standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return tidy(items)
    }

    private func windowMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += groupItems(.windowSize, standard: [
            standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        items.append(.separator())
        items += groupItems(.windowArrangement, standard: [standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))])
        items += groupItems(.windowList, standard: [])
        return tidy(items)
    }

    private func customMenuItems(_ title: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for case .menu(let menuTitle, let content) in AppRuntime.commandEntries() where menuTitle == title {
            items += nsItems(content())
        }
        return tidy(items)
    }

    /// Standard items of a placement with the app's groups applied (replacing / before / after).
    private func groupItems(_ placement: CommandGroupPlacement, standard: [NSMenuItem]) -> [NSMenuItem] {
        var before: [NSMenuItem] = []
        var after: [NSMenuItem] = []
        var replacement: [NSMenuItem]?
        for case .group(let groupPlacement, let position, let content) in AppRuntime.commandEntries() where groupPlacement == placement {
            let items = nsItems(content())
            switch position {
            case .before: before += items
            case .after: after += items
            case .replacing: replacement = (replacement ?? []) + items
            }
        }
        return before + (replacement ?? standard) + after
    }

    /// Drops leading, trailing and doubled separators.
    private func tidy(_ items: [NSMenuItem]) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        for item in items {
            if item.isSeparatorItem && (result.isEmpty || result.last?.isSeparatorItem == true) { continue }
            result.append(item)
        }
        while result.last?.isSeparatorItem == true { result.removeLast() }
        return result
    }

    // MARK: Conversion

    func nsItems(_ items: [MenuItem]) -> [NSMenuItem] {
        items.flatMap { item -> [NSMenuItem] in
            switch item {
            case let .button(title, systemImage, shortcut, isEnabled, _, action):
                let menuItem = actionItem(title: title, shortcut: shortcut, isEnabled: isEnabled) { action() }
                if let systemImage { menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
                return [menuItem]
            case let .toggle(title, isOn, shortcut, isEnabled, set):
                let menuItem = actionItem(title: title, shortcut: shortcut, isEnabled: isEnabled) { set(!isOn) }
                menuItem.state = isOn ? .on : .off
                return [menuItem]
            case let .submenu(title, systemImage, children):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let systemImage { menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                for child in nsItems(children) { submenu.addItem(child) }
                menuItem.submenu = submenu
                return [menuItem]
            case let .section(title, children):
                var result: [NSMenuItem] = [.separator()]
                if let title, !title.isEmpty { result.append(NSMenuItem.sectionHeader(title: title)) }
                return result + nsItems(children) + [.separator()]
            case .divider:
                return [.separator()]
            case .label(let text):
                let menuItem = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                return [menuItem]
            }
        }
    }

    private func actionItem(title: String, shortcut: KeyboardShortcut?, isEnabled: Bool, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let box = MenuAction(action: action, isEnabled: isEnabled)
        actions.append(box)
        if actions.count > 2000 { actions.removeFirst(1000) }
        let item = NSMenuItem(title: title, action: #selector(MenuAction.perform(_:)), keyEquivalent: "")
        item.target = box
        if let shortcut {
            item.keyEquivalent = Self.keyEquivalent(shortcut.key)
            item.keyEquivalentModifierMask = Self.modifiers(shortcut.modifiers)
        }
        return item
    }

    static func keyEquivalent(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .leftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .rightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        default: String(key.character).lowercased()
        }
    }

    static func modifiers(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// Target of a command menu item.
@MainActor
final class MenuAction: NSObject, NSMenuItemValidation {
    let action: @MainActor () -> Void
    let isEnabled: Bool

    init(action: @escaping @MainActor () -> Void, isEnabled: Bool) {
        self.action = action
        self.isEnabled = isEnabled
    }

    @objc func perform(_ sender: Any?) { action() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isEnabled }
}
#endif
