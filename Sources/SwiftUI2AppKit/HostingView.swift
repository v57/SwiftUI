#if canImport(AppKit)
import AppKit
import SwiftUI2Core

/// Hosts a SwiftUI2 view graph in an NSView. Graph updates are coalesced and run once per run-loop
/// turn (before the run loop sleeps, like SwiftUI/Core Animation transactions); resizing lays out
/// synchronously.
@MainActor
open class GraphHostingView: NSView {
    public private(set) var graph: ViewGraph!
    private var backend: AppKitBackend!
    private var updateScheduled = false
    private var observer: CFRunLoopObserver?

    public init(makeGraph: (any RenderBackend) -> ViewGraph) {
        super.init(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        wantsLayer = true
        backend = AppKitBackend(rootView: self)
        graph = makeGraph(backend)
        graph.onNeedsUpdate = { [weak self] in self?.scheduleUpdate() }
        graph.onNeedsAnimationFrame = { [weak self] in self?.startDisplayLink() }
        graph.clock = { CACurrentMediaTime() }
        applyAppearance()
        graph.setProposedSize(ProposedViewSize(bounds.size))
        graph.update()
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        graph.update()
    }

    private var colorScheme: ColorScheme?

    private func applyAppearance() {
        let scheme: ColorScheme = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        guard scheme != colorScheme else { return }
        colorScheme = scheme
        graph.setEnvironment { $0.colorScheme = scheme }
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        displayLink?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        graph?.tearDown()
    }

    open override var isFlipped: Bool { true }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, let character = characters.first else {
            return super.performKeyEquivalent(with: event)
        }
        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let key: KeyEquivalent = event.keyCode == 36 ? .return : event.keyCode == 53 ? .escape : KeyEquivalent(Character(character.lowercased()))
        if graph.performKeyboardShortcut(KeyboardShortcut(key, modifiers: modifiers)) {
            graph.update()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    open override func keyDown(with event: NSEvent) {
        if !performKeyEquivalent(with: event) { super.keyDown(with: event) }
    }

    open override var acceptsFirstResponder: Bool { true }

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        graph?.setProposedSize(ProposedViewSize(newSize))
        graph?.update()
    }

    open override var intrinsicContentSize: NSSize {
        graph.sizeThatFits(.unspecified)
    }

    open override var fittingSize: NSSize {
        graph.sizeThatFits(.unspecified)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        graph.sizeThatFits(proposal)
    }

    private var displayLink: CADisplayLink?

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        graph.renderAnimationFrame()
        if !graph.hasActiveAnimations {
            link.invalidate()
            displayLink = nil
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        if observer == nil {
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_000_000) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.flush() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func flush() {
        guard updateScheduled else { return }
        updateScheduled = false
        graph.update()
    }
}

/// `NSHostingView` equivalent.
@MainActor
open class NSHostingView<Content: View>: GraphHostingView {
    public init(rootView: Content) {
        super.init(makeGraph: { backend in ViewGraph(rootView: rootView, backend: backend) })
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var rootView: Content {
        get { fatalError("rootView getter is not supported") }
        set { graph.setRootView(newValue) }
    }
}

/// Runs an `App` with AppKit.
@MainActor
public enum AppKitAppRunner {
    private static var windows: [NSWindow] = []
    private static var toolbarControllers: [WindowToolbarController] = []
    private static var delegate: AppDelegate?
    /// The app's `@NSApplicationDelegateAdaptor` delegate; unhandled delegate messages go to it.
    nonisolated(unsafe) static var userDelegate: (NSObject & NSApplicationDelegate)?

    public static func install() {
        AppRuntime.runner = { descriptions in run(descriptions) }
    }

    static func run(_ descriptions: [WindowDescription]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.mainMenu = makeMenu(hasSettings: descriptions.contains { $0.role == .settings })
        for description in descriptions where description.role == .settings {
            delegate.settings = description
        }
        for description in descriptions where description.role == .main {
            let host = GraphHostingView(makeGraph: description.makeGraph)
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: CGSize(width: 900, height: 450)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = description.title.isEmpty ? ProcessInfo.processInfo.processName : description.title
            let baseTitle = window.title
            host.graph.onNavigationTitleChange = { [weak window] title in
                window?.title = title ?? baseTitle
            }
            window.contentView = host
            let toolbarController = WindowToolbarController(window: window, host: host)
            toolbarControllers.append(toolbarController)
            host.graph.onToolbarChange = { [weak toolbarController] toolbar in toolbarController?.update(toolbar) }
            // Like SwiftUI: the content's minimum size bounds the window, and the default frame is
            // `defaultSize` or the content's ideal size (at least 900x450, title bar included).
            let minimum = host.sizeThatFits(ProposedViewSize(width: 0, height: 0))
            window.contentMinSize = minimum
            let titleBar = window.frame.height - window.contentLayoutRect.height
            let frameSize: CGSize
            if let size = description.defaultSize {
                frameSize = size
            } else {
                let ideal = host.sizeThatFits(.unspecified)
                frameSize = CGSize(width: max(ideal.width, 900), height: max(ideal.height + titleBar, 450))
            }
            // Centered in the screen's visible frame (NSWindow.center() places windows higher).
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let origin = CGPoint(x: (visible.midX - frameSize.width / 2).rounded(), y: (visible.midY - frameSize.height / 2).rounded())
            window.setFrame(CGRect(origin: origin, size: frameSize), display: false)
            // SwiftUI restores window frames between launches.
            let autosaveName = "SwiftUI2.WindowGroup-\(description.title)-1"
            window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        app.activate()
        app.run()
        exit(0)
    }

    private static func makeMenu(hasSettings: Bool) -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        if hasSettings {
            let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
            settings.target = delegate
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
        }
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        return menu
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        var settings: WindowDescription?
        private var settingsWindow: NSWindow?

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            MainActor.assumeIsolated {
                AppKitAppRunner.userDelegate?.applicationShouldTerminateAfterLastWindowClosed?(sender) ?? true
            }
        }

        // Forward everything else to the adaptor delegate (open URLs, lifecycle callbacks, ...).
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return AppKitAppRunner.userDelegate?.responds(to: selector) ?? false
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if let target = AppKitAppRunner.userDelegate, target.responds(to: selector) { return target }
            return super.forwardingTarget(for: selector)
        }

        @MainActor @objc func showSettings(_ sender: Any?) {
            if let settingsWindow {
                settingsWindow.makeKeyAndOrderFront(nil)
                return
            }
            guard let settings else { return }
            let host = GraphHostingView(makeGraph: settings.makeGraph)
            let size = host.sizeThatFits(.unspecified)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: max(size.width, 300), height: max(size.height, 120))), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            settingsWindow = window
        }
    }
}
#endif
