#if canImport(AppKit)
import AppKit
import SwiftUI2Core

/// Mirrors a root's `WindowToolbar` into the window's `NSToolbar` (unified style, like SwiftUI on
/// macOS): a sidebar toggle for split views, the title aligned past the sidebar, plain buttons as
/// native toolbar items, other content as hosted views.
@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private weak var window: NSWindow?
    private weak var host: GraphHostingView?
    private var current = WindowToolbar()
    private var identifiers: [NSToolbarItem.Identifier] = []
    private var entries: [NSToolbarItem.Identifier: ToolbarEntry] = [:]
    private var hostedViews: [NSToolbarItem.Identifier: NSHostingView<AnyView>] = [:]

    static let toggleSidebar = NSToolbarItem.Identifier("SwiftUI2.toggleSidebar")
    static let sidebarSpacer = NSToolbarItem.Identifier("SwiftUI2.sidebarSpacer")
    static let title = NSToolbarItem.Identifier("SwiftUI2.title")

    /// The window title, drawn as an item so it can follow the sidebar like SwiftUI's.
    private let titleLabel = NSTextField(labelWithString: "")
    /// Pushes the title (and navigation items) past the sidebar column.
    private let spacerView = NSView()
    private var spacerWidth: NSLayoutConstraint?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []

    init(window: NSWindow, host: GraphHostingView) {
        self.window = window
        self.host = host
        super.init()
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = window.title
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        let width = spacerView.widthAnchor.constraint(equalToConstant: 1)
        width.isActive = true
        spacerView.heightAnchor.constraint(equalToConstant: 1).isActive = true
        spacerWidth = width
        observations.append(window.observe(\.title, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.titleLabel.stringValue = window.title }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateTitleColor()
                    self?.scheduleAlignment()
                }
            })
        }
        updateTitleColor()
    }

    private func updateTitleColor() {
        titleLabel.textColor = window?.isKeyWindow == true ? .labelColor : .tertiaryLabelColor
    }

    private var alignmentScheduled = false

    private func scheduleAlignment() {
        guard !alignmentScheduled else { return }
        alignmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.alignmentScheduled = false
                self?.alignToSidebar()
            }
        }
    }

    /// SwiftUI places the title (after navigation items) 10pt past the sidebar column.
    private func alignToSidebar() {
        guard current.chrome.hasSidebar, let spacerWidth, spacerView.window != nil else { return }
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        let next = titleLabel.window != nil ? titleLabel : nil
        guard let next else { return }
        let target = current.chrome.isSidebarVisible ? current.chrome.sidebarWidth + 10 : 0
        let actual = next.convert(next.bounds, to: nil).minX
        let width = max(0, spacerWidth.constant + target - actual)
        if abs(width - spacerWidth.constant) > 0.5 {
            spacerWidth.constant = width
            scheduleAlignment()
        }
    }

    func update(_ toolbar: WindowToolbar) {
        guard let window else { return }
        current = toolbar
        if toolbar.isEmpty {
            if window.toolbar != nil {
                window.toolbar = nil
                window.titleVisibility = .visible
            }
            return
        }
        if window.toolbar == nil {
            let nsToolbar = NSToolbar(identifier: "SwiftUI2.WindowToolbar")
            nsToolbar.delegate = self
            nsToolbar.displayMode = .iconOnly
            nsToolbar.allowsUserCustomization = false
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.toolbar = nsToolbar
        }

        var newEntries: [NSToolbarItem.Identifier: ToolbarEntry] = [:]
        var ids: [NSToolbarItem.Identifier] = []
        let items = toolbar.items
        func add(_ entry: ToolbarEntry) {
            let id = NSToolbarItem.Identifier("SwiftUI2.item.\(entry.id)")
            newEntries[id] = entry
            ids.append(id)
        }
        if toolbar.chrome.hasSidebar {
            if !toolbar.chrome.removesSidebarToggle { ids.append(Self.toggleSidebar) }
            items.filter(\.isSidebarItem).forEach(add)
            ids.append(Self.sidebarSpacer)
        }
        let main = items.filter { !$0.isSidebarItem }
        main.filter { $0.placement == .navigation || $0.placement == .cancellationAction || $0.placement == .topBarLeading }.forEach(add)
        ids.append(Self.title)
        let principal = main.filter { $0.placement == .principal }
        if !principal.isEmpty {
            ids.append(.flexibleSpace)
            principal.forEach(add)
        }
        let trailing = main.filter { ![.navigation, .cancellationAction, .topBarLeading, .principal].contains($0.placement) }
        if !trailing.isEmpty || !principal.isEmpty { ids.append(.flexibleSpace) }
        trailing.forEach(add)

        entries = newEntries
        if ids != identifiers {
            identifiers = ids
            hostedViews = hostedViews.filter { newEntries[$0.key] != nil }
            rebuild()
        } else {
            refreshItems()
        }
        scheduleAlignment()
    }

    // Replaces all items (identifier lists changed).
    private func rebuild() {
        guard let nsToolbar = window?.toolbar else { return }
        while !nsToolbar.items.isEmpty { nsToolbar.removeItem(at: 0) }
        for (index, id) in identifiers.enumerated() { nsToolbar.insertItem(withItemIdentifier: id, at: index) }
    }

    private func refreshItems() {
        guard let nsToolbar = window?.toolbar else { return }
        for item in nsToolbar.items {
            if let entry = entries[item.itemIdentifier] { configure(item, with: entry) }
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.title {
            item.view = titleLabel
            item.label = "Title"
            item.isBordered = false
            return item
        }
        if id == Self.sidebarSpacer {
            item.view = spacerView
            item.isBordered = false
            return item
        }
        if id == Self.toggleSidebar {
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.label = "Toggle Sidebar"
            item.toolTip = "Hide or show the Sidebar"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleSidebar(_:))
            return item
        }
        guard let entry = entries[id] else { return nil }
        configure(item, with: entry)
        return item
    }

    private func configure(_ item: NSToolbarItem, with entry: ToolbarEntry) {
        if let button = entry.button {
            item.view = nil
            if let name = button.systemImage {
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: button.title ?? button.help)
                item.title = ""
            } else {
                item.image = nil
                item.title = button.title ?? ""
            }
            item.label = button.title ?? button.help ?? ""
            item.toolTip = button.help
            item.isBordered = true
            item.isEnabled = button.isEnabled
            item.autovalidates = false
            item.target = self
            item.action = #selector(performItem(_:))
            item.isNavigational = entry.placement == .navigation
        } else {
            let view = AnyView(entry.content.environment(\.self, entry.environment))
            if let hosted = hostedViews[item.itemIdentifier] {
                hosted.rootView = view
            } else {
                let hosted = NSHostingView(rootView: view)
                hostedViews[item.itemIdentifier] = hosted
                item.view = hosted
            }
            if let hosted = hostedViews[item.itemIdentifier] {
                let size = hosted.sizeThatFits(.unspecified)
                hosted.frame.size = size
            }
        }
    }

    @objc private func performItem(_ sender: NSToolbarItem) {
        entries[sender.itemIdentifier]?.button?.action()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        current.chrome.toggleSidebar?()
    }
}
#endif
