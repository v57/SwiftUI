#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
import _SwiftUICore

extension AppKitAppRunner {
    /// Runtime hooks for settings, window visibility, documents and status items.
    static func installSceneSupport() {
        AppRuntime.openSettings = { delegate?.showSettings(nil) }
        AppRuntime.isWindowOpen = { id in
            openWindows.contains { entry in
                guard let window = entry.window, window.isVisible else { return false }
                return scenes[entry.sceneIndex].id == id
            }
        }
        AppRuntime.newDocument = { newDocument() }
        for scene in scenes {
            if let extra = scene.menuBarExtra { statusItems.append(StatusItemController(scene: scene, extra: extra)) }
        }
    }

    nonisolated(unsafe) static var statusItems: [StatusItemController] = []

    /// The native window for a scene's chrome (`windowStyle`, utility panels, levels, toolbar style).
    static func makeNativeWindow(for description: WindowDescription) -> NSWindow {
        let window: NSWindow
        switch description.kind {
        case .utility:
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            window = panel
        case .plain:
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        case .hiddenTitleBar:
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        case .standard:
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
        switch description.level {
        case .floating: window.level = .floating
        case .desktop: window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        case .automatic, .normal: break
        }
        switch description.toolbarStyle {
        case .unified: window.toolbarStyle = .unified
        case .unifiedCompact: window.toolbarStyle = .unifiedCompact
        case .expanded: window.toolbarStyle = .expanded
        case .automatic: break
        }
        if description.resizability == .contentSize, description.kind == .utility { window.styleMask.remove(.resizable) }
        return window
    }

    // MARK: Documents

    static var documentSceneIndex: Int? { scenes.firstIndex { $0.document != nil } }

    static func newDocument() {
        guard let index = documentSceneIndex, let make = scenes[index].document?.makeNew else { return }
        makeWindow(sceneIndex: index, value: AnyHashable(_DocumentWindowValue(handle: make())))
    }

    static func openDocument() {
        guard let index = documentSceneIndex, let document = scenes[index].document else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        let types = document.readableTypeIdentifiers.compactMap { UTType($0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openDocument(at: url) }
    }

    static func openDocument(at url: URL) {
        guard let index = documentSceneIndex, let document = scenes[index].document else { return }
        // Bring an already open document forward.
        if let open = openWindows.first(where: { ($0.value?.base as? _DocumentWindowValue)?.handle.fileURL == url })?.window {
            open.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let handle = try document.open(url)
            makeWindow(sceneIndex: index, value: AnyHashable(_DocumentWindowValue(handle: handle)))
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func documentHandle(of window: NSWindow?) -> (any _DocumentHandle)? {
        guard let window else { return nil }
        return (openWindows.first { $0.window === window }?.value?.base as? _DocumentWindowValue)?.handle
    }

    /// Saves the key window's document; asks for a location when it has none (or `saveAs`).
    @discardableResult
    static func saveDocument(in window: NSWindow?, saveAs: Bool) -> Bool {
        guard let handle = documentHandle(of: window) else { return false }
        var url = saveAs ? nil : handle.fileURL
        var type = handle.writableTypeIdentifiers.first ?? UTType.data.identifier
        if url == nil {
            let panel = NSSavePanel()
            let types = handle.writableTypeIdentifiers.compactMap { UTType($0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
            panel.nameFieldStringValue = handle.fileURL?.lastPathComponent ?? "Untitled"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
            if let chosenType = UTType(filenameExtension: chosen.pathExtension), handle.writableTypeIdentifiers.contains(chosenType.identifier) { type = chosenType.identifier }
        }
        guard let url else { return false }
        do {
            try handle.write(to: url, typeIdentifier: type)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            updateDocumentWindow(window)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Title, represented file and edited state follow the document.
    static func configureDocumentWindow(_ window: NSWindow, value: AnyHashable?, baseTitle: String) {
        guard value?.base is _DocumentWindowValue else { return }
        updateDocumentWindow(window)
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak window] timer in
            let alive = MainActor.assumeIsolated { () -> Bool in
                guard let window, window.isVisible || window.isMiniaturized else { return false }
                updateDocumentWindow(window)
                return true
            }
            if !alive { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneDelegate(for: window).isDocument = true
    }

    nonisolated(unsafe) static var sceneDelegates: [ObjectIdentifier: SceneWindowDelegate] = [:]

    /// The window's delegate (created on first use).
    static func sceneDelegate(for window: NSWindow) -> SceneWindowDelegate {
        if let existing = sceneDelegates[ObjectIdentifier(window)] { return existing }
        let delegate = SceneWindowDelegate()
        sceneDelegates[ObjectIdentifier(window)] = delegate
        window.delegate = delegate
        return delegate
    }

    /// Applies views' window behavior (`windowResizeBehavior`, `navigationDocument`, ...).
    static func apply(_ configuration: WindowConfiguration, to window: NSWindow, host: GraphHostingView, sceneResizable: Bool) {
        sceneDelegate(for: window).configuration = configuration
        func set(_ mask: NSWindow.StyleMask, _ on: Bool) { if on { window.styleMask.insert(mask) } else { window.styleMask.remove(mask) } }
        if window.styleMask.contains(.titled) {
            set(.resizable, configuration.resizeBehavior == .disabled ? false : sceneResizable)
            set(.miniaturizable, configuration.minimizeBehavior != .disabled)
            set(.closable, configuration.dismissBehavior != .disabled)
        }
        switch configuration.fullScreenBehavior {
        case .disabled:
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
        case .enabled:
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
        case .automatic: break
        }
        if let url = configuration.representedURL, documentHandle(of: window) == nil { window.representedURL = url }
        if let background = configuration.background { window.backgroundColor = NSColor(background) }
        if let hidden = configuration.isToolbarHidden { window.toolbar?.isVisible = !hidden }
        if let hidden = configuration.isToolbarBackgroundHidden { window.titlebarAppearsTransparent = hidden }
        host.acceptsFirstMouseEvents = configuration.allowsActivationEvents ?? false
    }

    static func updateDocumentWindow(_ window: NSWindow?) {
        guard let window, let handle = documentHandle(of: window) else { return }
        if window.representedURL != handle.fileURL { window.representedURL = handle.fileURL }
        let title = handle.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        if window.title != title { window.title = title }
        if window.isDocumentEdited != handle.isEdited { window.isDocumentEdited = handle.isEdited }
    }
}

/// Window delegate of scene windows: document save prompts, full-screen options and live resize.
final class SceneWindowDelegate: NSObject, NSWindowDelegate {
    var isDocument = false
    nonisolated(unsafe) var configuration = WindowConfiguration()

    func windowWillStartLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated { for observer in configuration.resizeObservers { observer.notify(true) } }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated { for observer in configuration.resizeObservers { observer.notify(false) } }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        guard configuration.toolbarFullScreenVisibility == .onHover else { return proposedOptions }
        return proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .fullScreen])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            if let confirm = configuration.closeConfirmation {
                confirm()
                return false
            }
            guard isDocument, let handle = AppKitAppRunner.documentHandle(of: sender), handle.isEdited else { return true }
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to the document “\(sender.title)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save…")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return AppKitAppRunner.saveDocument(in: sender, saveAs: false)
            case .alertThirdButtonReturn: return true
            default: return false
            }
        }
    }
}

extension AppKitAppRunner.AppDelegate {
    @MainActor @objc func newDocument(_ sender: Any?) { AppKitAppRunner.newDocument() }
    @MainActor @objc func openDocument(_ sender: Any?) { AppKitAppRunner.openDocument() }
    @MainActor @objc func saveDocument(_ sender: Any?) { AppKitAppRunner.saveDocument(in: NSApp.keyWindow, saveAs: false) }
    @MainActor @objc func saveDocumentAs(_ sender: Any?) { AppKitAppRunner.saveDocument(in: NSApp.keyWindow, saveAs: true) }

    @MainActor @objc func toggleUtilityWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if AppRuntime.isWindowOpen?(id) == true { AppRuntime.dismissWindow?(id, nil) } else { AppRuntime.openWindow?(id, nil) }
    }

    @MainActor @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("saveDocument:")), Selector(("saveDocumentAs:")):
            return AppKitAppRunner.documentHandle(of: NSApp.keyWindow) != nil
        default:
            return true
        }
    }
}

// MARK: - MenuBarExtra

/// A status item showing a menu or a popover window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let scene: WindowDescription
    let extra: MenuBarExtraDescription
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?

    init(scene: WindowDescription, extra: MenuBarExtraDescription) {
        self.scene = scene
        self.extra = extra
        super.init()
        sync()
        if extra.isInserted != nil {
            // isInserted: insert/remove the item as the binding changes.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func sync() {
        let inserted = extra.isInserted?.wrappedValue ?? true
        if inserted, item == nil { install() }
        if !inserted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let symbol = extra.systemImage, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: extra.title) {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = extra.title
        }
        item.button?.toolTip = extra.title
        item.behavior = extra.isInserted == nil ? [] : .removalAllowed
        if extra.isWindowStyle {
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
        } else {
            let menu = NSMenu(title: extra.title)
            menu.delegate = self
            item.menu = menu
        }
        self.item = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for nsItem in AppKitAppRunner.menuBar?.nsItems(extra.menuItems()) ?? [] { menu.addItem(nsItem) }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let host = GraphHostingView(makeGraph: scene.makeGraph)
        let size = host.sizeThatFits(.unspecified)
        host.frame = CGRect(origin: .zero, size: size)
        let controller = NSViewController()
        controller.view = host
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        self.popover = popover
    }
}
#endif
