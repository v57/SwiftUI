#if os(Windows)
import Foundation
import CSwiftUI2WinUI
import SwiftUI2Core
import UniformTypeIdentifiers

// MARK: - Keyboard

/// Keys the host sends as negative codes (`swiftui2_key`); others are Unicode scalars.
enum WinUIKeys {
    static func key(_ code: Int32) -> KeyEquivalent? {
        switch code {
        case -1: return KeyEquivalent.return
        case -2: return KeyEquivalent.escape
        case -3: return KeyEquivalent.delete
        case -4: return KeyEquivalent.deleteForward
        case -5: return KeyEquivalent.tab
        case -6: return KeyEquivalent.space
        case -7: return KeyEquivalent.upArrow
        case -8: return KeyEquivalent.downArrow
        case -9: return KeyEquivalent.leftArrow
        case -10: return KeyEquivalent.rightArrow
        case -11: return KeyEquivalent.home
        case -12: return KeyEquivalent.end
        case -13: return KeyEquivalent.pageUp
        case -14: return KeyEquivalent.pageDown
        default:
            guard code > 0, let scalar = Unicode.Scalar(UInt32(code)) else { return nil }
            return KeyEquivalent(Character(scalar))
        }
    }

    /// Host modifier bits: 1 Shift, 2 Ctrl, 4 Alt, 8 Windows key. SwiftUI's ⌘ shortcuts are Ctrl
    /// shortcuts on Windows (as on other PC platforms); ⌃ maps to the Windows key, ⌥ to Alt.
    static func modifiers(_ raw: Int32) -> EventModifiers {
        var modifiers: EventModifiers = []
        if raw & 1 != 0 { modifiers.insert(.shift) }
        if raw & 2 != 0 { modifiers.insert(.command) }
        if raw & 4 != 0 { modifiers.insert(.option) }
        if raw & 8 != 0 { modifiers.insert(.control) }
        return modifiers
    }

    /// The modifiers a shortcut is written with on Windows ("Ctrl+Shift+S").
    static func describe(_ shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("Ctrl") }
        if shortcut.modifiers.contains(.control) { parts.append("Win") }
        if shortcut.modifiers.contains(.option) { parts.append("Alt") }
        if shortcut.modifiers.contains(.shift) { parts.append("Shift") }
        let key: String
        switch shortcut.key {
        case .return: key = "Enter"
        case .escape: key = "Esc"
        case .delete: key = "Backspace"
        case .deleteForward: key = "Del"
        case .tab: key = "Tab"
        case .space: key = "Space"
        case .upArrow: key = "Up"
        case .downArrow: key = "Down"
        case .leftArrow: key = "Left"
        case .rightArrow: key = "Right"
        case .home: key = "Home"
        case .end: key = "End"
        case .pageUp: key = "PgUp"
        case .pageDown: key = "PgDn"
        default: key = String(shortcut.key.character).uppercased()
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

extension WinUIHost {
    /// A key event from the window. Like the AppKit host: `onKeyPress` handlers first, then (key
    /// down only) the menu bar's and the views' keyboard shortcuts. Returns whether it was handled.
    func key(code: Int32, characters: String, modifiers raw: Int32, phase: KeyPress.Phases) -> Bool {
        guard let key = WinUIKeys.key(code) else { return false }
        let modifiers = WinUIKeys.modifiers(raw)
        var handled = graph.handleKeyPress(KeyPress(key: key, characters: characters, modifiers: modifiers, phase: phase))
        if !handled, phase != .up {
            let shortcut = KeyboardShortcut(key, modifiers: modifiers)
            handled = menuBar.perform(shortcut) || graph.performKeyboardShortcut(shortcut)
        }
        if handled { flushNow() }
        return handled
    }
}

// MARK: - Menu bar

/// The window's menu bar: the app's `.commands` placed into the standard Windows menus (File,
/// Edit, View, custom menus, Window, Help), like the AppKit backend's main menu. Shown only when
/// the app declares commands. Re-evaluated after each update and sent to the host when it changed.
@MainActor
final class WinUIMenuBar {
    private weak var host: WinUIHost?
    private var actions: [String: @MainActor () -> Void] = [:]
    private var shortcuts: [(KeyboardShortcut, String)] = []
    private var description = ""
    private var nextID = 0

    init(host: WinUIHost) { self.host = host }

    func refresh() {
        guard let host else { return }
        actions = [:]
        shortcuts = []
        nextID = 0
        var lines: [String] = []
        if !AppRuntime.commands.isEmpty {
            for (title, items) in menus() where !items.isEmpty {
                lines.append(line(depth: 0, kind: "m", id: "", title: title))
                encode(items, depth: 1, into: &lines)
            }
        }
        let updated = lines.joined(separator: "\n")
        guard updated != description else { return }
        description = updated
        _ = WinUIPlatform.call(host.view, .setMenuBar, updated)
    }

    /// Runs the enabled menu item with this shortcut.
    func perform(_ shortcut: KeyboardShortcut) -> Bool {
        guard let id = shortcuts.first(where: { $0.0 == shortcut })?.1, let action = actions[id] else { return false }
        action()
        return true
    }

    func perform(id: String) {
        actions[id]?()
    }

    // MARK: Menus

    private func menus() -> [(String, [MenuItem])] {
        let entries = AppRuntime.commandEntries()
        func group(_ placement: CommandGroupPlacement, _ standard: [MenuItem] = []) -> [MenuItem] {
            var before: [MenuItem] = [], after: [MenuItem] = [], replacement: [MenuItem]?
            for case .group(let groupPlacement, let position, let content) in entries where groupPlacement == placement {
                let items = content()
                switch position {
                case .before: before += items
                case .after: after += items
                case .replacing: replacement = (replacement ?? []) + items
                }
            }
            return before + (replacement ?? standard) + after
        }
        let window = host
        let newWindow: MenuItem = .button(title: "New Window", systemImage: nil, shortcut: KeyboardShortcut("n", modifiers: .command),
                                          isEnabled: true, isDestructive: false, action: { AppRuntime.openWindow?(nil, nil) })
        let close: MenuItem = .button(title: "Close Window", systemImage: nil, shortcut: KeyboardShortcut("w", modifiers: .command),
                                      isEnabled: true, isDestructive: false, action: { if let window { sui_close_window(window.view) } })
        let hasWindowGroup = WinUIAppRunner.scenes.contains { !$0.isSingle && $0.valueType == nil && $0.role == .main }
        var result: [(String, [MenuItem])] = []
        result.append(("File", group(.newItem, hasWindowGroup ? [newWindow] : []) + [.divider] + group(.saveItem) + group(.importExport)
                       + group(.printItem) + [.divider, close] + group(.appTermination)))
        result.append(("Edit", group(.undoRedo) + [.divider] + group(.pasteboard) + group(.textEditing) + group(.textFormatting)))
        result.append(("View", group(.toolbar) + group(.sidebar)))
        var titles: [String] = []
        for case .menu(let title, _) in entries where !titles.contains(title) { titles.append(title) }
        for title in titles {
            var items: [MenuItem] = []
            for case .menu(let menuTitle, let content) in entries where menuTitle == title { items += content() }
            result.append((title, items))
        }
        result.append(("Window", group(.windowSize) + group(.windowArrangement) + group(.windowList) + group(.singleWindowList)))
        result.append(("Help", group(.appInfo) + group(.appSettings) + group(.help)))
        return result.map { ($0.0, tidy($0.1)) }
    }

    /// Drops leading, trailing and doubled dividers.
    private func tidy(_ items: [MenuItem]) -> [MenuItem] {
        var result: [MenuItem] = []
        for item in items {
            if case .divider = item, result.isEmpty || { if case .divider = result.last! { true } else { false } }() { continue }
            result.append(item)
        }
        while let last = result.last, case .divider = last { result.removeLast() }
        return result
    }

    // MARK: Encoding (one item per line: depth, kind, id, title, shortcut, enabled, checked; U+001F separated)

    private func line(depth: Int, kind: String, id: String, title: String, shortcut: KeyboardShortcut? = nil, enabled: Bool = true, checked: Bool = false) -> String {
        [String(depth), kind, id, title, shortcut.map(WinUIKeys.describe) ?? "", enabled ? "1" : "0", checked ? "1" : "0"].joined(separator: "\u{1F}")
    }

    private func register(_ action: @escaping @MainActor () -> Void, shortcut: KeyboardShortcut?, enabled: Bool) -> String {
        nextID += 1
        let id = "m\(nextID)"
        if enabled {
            actions[id] = action
            if let shortcut { shortcuts.append((shortcut, id)) }
        }
        return id
    }

    private func encode(_ items: [MenuItem], depth: Int, into lines: inout [String]) {
        for item in items {
            switch item {
            case let .button(title, _, shortcut, isEnabled, _, action):
                let id = register(action, shortcut: shortcut, enabled: isEnabled)
                lines.append(line(depth: depth, kind: "b", id: id, title: title, shortcut: shortcut, enabled: isEnabled))
            case let .toggle(title, isOn, shortcut, isEnabled, set):
                let id = register({ set(!isOn) }, shortcut: shortcut, enabled: isEnabled)
                lines.append(line(depth: depth, kind: "t", id: id, title: title, shortcut: shortcut, enabled: isEnabled, checked: isOn))
            case let .submenu(title, _, children):
                lines.append(line(depth: depth, kind: "s", id: "", title: title))
                encode(children, depth: depth + 1, into: &lines)
            case let .section(title, children):
                lines.append(line(depth: depth, kind: "-", id: "", title: ""))
                if let title, !title.isEmpty { lines.append(line(depth: depth, kind: "l", id: "", title: title, enabled: false)) }
                encode(children, depth: depth, into: &lines)
                lines.append(line(depth: depth, kind: "-", id: "", title: ""))
            case .divider:
                lines.append(line(depth: depth, kind: "-", id: "", title: ""))
            case .label(let text):
                lines.append(line(depth: depth, kind: "l", id: "", title: text, enabled: false))
            }
        }
    }
}

// MARK: - File dialogs

/// `fileImporter` / `fileExporter` / `fileDialog...`: the host shows the Windows App SDK pickers
/// asynchronously and reports the chosen paths back (`WinUIHost.Event.fileDialog`).
@MainActor
final class WinUIFileDialogs {
    private var pending: [Int: @MainActor ([URL]?) -> Void] = [:]
    private var nextID = 1

    /// Request fields (U+001F separated): id, kind (open/save/folder), multiple, default filename,
    /// title/message, confirmation label, extensions (";"-separated, empty: any).
    func present(_ request: FileDialogRequest, host: sui_ref, completion: @escaping @MainActor ([URL]?) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        let folders = request.contentTypes == [UTType.folder.identifier] || (request.canChooseDirectories && request.kind == .open && request.contentTypes.isEmpty)
        let kind = request.kind == .save ? "save" : folders ? "folder" : "open"
        var extensions: [String] = []
        for identifier in request.contentTypes {
            if let known = Self.abstractExtensions[identifier] {
                extensions += known
            } else if let type = UTType(identifier), let ext = type.preferredFilenameExtension {
                extensions.append(ext)
            } else {
                extensions = [] // a type without extensions (e.g. public.data): anything
                break
            }
        }
        let fields = [String(id), kind, request.allowsMultipleSelection ? "1" : "0", request.defaultFilename ?? "",
                      request.options.message ?? "", request.options.confirmationLabel ?? "", extensions.joined(separator: ";")]
        if WinUIPlatform.call(host, .fileDialog, fields.joined(separator: "\u{1F}")) == nil {
            // The host could not show a picker.
            complete(id: id, paths: nil)
        }
    }

    /// Abstract types the pickers can still filter by their common extensions.
    static let abstractExtensions: [String: [String]] = [
        "public.image": ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff", "ico"],
        "public.text": ["txt", "md", "csv", "json", "xml", "html", "log"],
        "public.plain-text": ["txt", "text", "log"],
        "public.movie": ["mp4", "mov", "m4v", "avi", "mkv", "wmv"],
        "public.video": ["mp4", "mov", "m4v", "avi", "mkv", "wmv"],
        "public.audio": ["mp3", "m4a", "wav", "aac", "flac", "wma"],
        "public.source-code": ["swift", "c", "h", "cpp", "cs", "js", "ts", "py"],
    ]

    func complete(id: Int, paths: [String]?) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        completion(paths.map { $0.map { URL(fileURLWithPath: $0) } })
    }
}
#endif
