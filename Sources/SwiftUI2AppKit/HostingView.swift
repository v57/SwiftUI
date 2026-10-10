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
        // Controls follow the design SwiftUI picks for the app's deployment target.
        graph.setEnvironment { $0._controlDesign = AppKitBackend.controlDesign }
        graph.onNeedsUpdate = { [weak self] in self?.scheduleUpdate() }
        graph.onNeedsAnimationFrame = { [weak self] in self?.startDisplayLink() }
        graph.clock = { CACurrentMediaTime() }
        applyAppearance()
        graph.setProposedSize(ProposedViewSize(bounds.size))
        graph.update()
    }

    private var keyObservers: [NSObjectProtocol] = []

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        firstResponderObservation = nil
        guard let window else { return }
        // \.appearsActive follows the window's key state.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAppearsActive() }
            })
        }
        updateAppearsActive()
        // Focused values follow the window's first responder.
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
    }

    private var firstResponderObservation: NSKeyValueObservation?

    private func firstResponderChanged(_ responder: NSResponder?) {
        var view = responder as? NSView
        // Field editors stand in for the text field being edited.
        if let textView = view as? NSTextView, textView.isFieldEditor, let field = textView.delegate as? NSView { view = field }
        while let current = view, current !== self {
            if let node = (current as? PlatformNodeView)?.node {
                graph.setFocusedNode(node)
                return
            }
            view = current.superview
        }
        graph.setFocusedNode(nil)
    }

    // MARK: Responder-chain commands

    /// `onCommand`, `onCopyCommand`, `copyable`, ...: actions some view handles are routed to a
    /// trampoline implementing that selector.
    open override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        let name = NSStringFromSelector(action)
        if graph.canHandleCommand(name) { return CommandTrampoline.target(for: action, graph: graph) }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    open override func flagsChanged(with event: NSEvent) {
        graph.handleModifierFlags(Self.modifiers(event.modifierFlags))
        super.flagsChanged(with: event)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    private func updateAppearsActive() {
        let active = window?.isKeyWindow ?? true
        if window?.isKeyWindow == true { FocusedValuesCenter.shared.activate(graph) }
        graph.setEnvironment { $0.appearsActive = active }
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
        if graph.handleKeyPress(Self.keyPress(event, phase: event.isARepeat ? .repeat : .down)) {
            graph.update()
            return
        }
        if !performKeyEquivalent(with: event) { super.keyDown(with: event) }
    }

    open override func keyUp(with event: NSEvent) {
        if graph.handleKeyPress(Self.keyPress(event, phase: .up)) {
            graph.update()
            return
        }
        super.keyUp(with: event)
    }

    /// Edit > Paste routed to `onPasteCommand` handlers.
    @objc open func paste(_ sender: Any?) {
        let types = (NSPasteboard.general.types ?? []).map(\.rawValue)
        if graph.handlePaste(AppKitBackend.pasteboardProviders(), types: types) { graph.update() }
    }

    static func keyPress(_ event: NSEvent, phase: KeyPress.Phases) -> KeyPress {
        var modifiers: EventModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let characters = event.characters ?? ""
        let key: KeyEquivalent
        switch event.keyCode {
        case 36, 76: key = .return
        case 53: key = .escape
        case 51: key = .delete
        case 117: key = .deleteForward
        case 48: key = .tab
        case 49: key = .space
        case 126: key = .upArrow
        case 125: key = .downArrow
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        default: key = KeyEquivalent(event.charactersIgnoringModifiers?.lowercased().first ?? " ")
        }
        return KeyPress(key: key, characters: characters, modifiers: modifiers, phase: phase)
    }

    open override var acceptsFirstResponder: Bool { true }

    /// Click-through for inactive windows (`allowsWindowActivationEvents`).
    var acceptsFirstMouseEvents = false
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstMouseEvents || super.acceptsFirstMouse(for: event) }

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
    static var windows: [NSWindow] = []
    static var toolbarControllers: [WindowToolbarController] = []
    static var delegate: AppDelegate?
    /// The app's `@NSApplicationDelegateAdaptor` delegate; unhandled delegate messages go to it.
    nonisolated(unsafe) static var userDelegate: (NSObject & NSApplicationDelegate)?

    public static func install() {
        AppRuntime.runner = { descriptions in run(descriptions) }
    }

    /// Open windows with the scene and presented value they came from.
    struct OpenWindow {
        weak var window: NSWindow?
        let sceneIndex: Int
        let value: AnyHashable?
    }
    static var scenes: [WindowDescription] = []
    static var openWindows: [OpenWindow] = []
    static var menuBar: MenuBarController?

    static func run(_ descriptions: [WindowDescription]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        scenes = descriptions
        for description in descriptions where description.role == .settings {
            delegate.settings = description
        }
        let menuBar = MenuBarController(
            appName: ProcessInfo.processInfo.processName,
            hasSettings: descriptions.contains { $0.role == .settings },
            hasWindowGroup: descriptions.contains { $0.opensAtLaunch && !$0.isSingle },
            settingsTarget: delegate
        )
        menuBar.hasDocuments = descriptions.contains { $0.document != nil }
        menuBar.utilityWindows = descriptions.filter { $0.kind == .utility }.compactMap { scene in scene.id.map { (scene.title, $0) } }
        installSceneSupport()
        self.menuBar = menuBar
        app.mainMenu = menuBar.makeMainMenu()
        AppRuntime.openWindow = { id, value in open(id: id, value: value) }
        AppRuntime.dismissWindow = { id, value in dismiss(id: id, value: value) }
        // Like SwiftUI, the first window scene opens at launch (plus scenes presented at launch;
        // document apps start with an untitled document).
        if let first = descriptions.firstIndex(where: { $0.opensAtLaunch }) {
            makeWindow(sceneIndex: first, value: nil)
        } else if descriptions.contains(where: { $0.document?.makeNew != nil }) {
            newDocument()
        }
        for (index, scene) in descriptions.enumerated() where scene.launchBehavior == .presented && !scene.opensAtLaunch {
            makeWindow(sceneIndex: index, value: nil)
        }
        app.activate()
        if let path = ProcessInfo.processInfo.environment["SWIFTUI2_SNAPSHOT"] { scheduleSnapshot(to: path) }
        app.run()
        exit(0)
    }

    /// Debugging aid: `SWIFTUI2_SNAPSHOT=/path/shot.png` renders each window (including its
    /// title bar and toolbar) to `shot.png`, `shot-1.png`, … after `SWIFTUI2_SNAPSHOT_DELAY`
    /// seconds (default 3), without needing screen recording access. `SWIFTUI2_SNAPSHOT_EXIT=1`
    /// quits afterwards.
    private static func scheduleSnapshot(to path: String) {
        let environment = ProcessInfo.processInfo.environment
        let delay = environment["SWIFTUI2_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let base = URL(fileURLWithPath: path)
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            for (index, window) in windows.enumerated() {
                guard let frameView = window.contentView?.superview ?? window.contentView,
                      let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                let url = index == 0 ? base : base.deletingLastPathComponent()
                    .appendingPathComponent("\(base.deletingPathExtension().lastPathComponent)-\(index).png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
            if environment["SWIFTUI2_SNAPSHOT_EXIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    /// `openWindow(id:value:)`: focuses a window already showing the value, otherwise opens one.
    static func open(id: String?, value: AnyHashable?) {
        let index = scenes.firstIndex { scene in
            guard scene.role == .main else { return false }
            if let id { return scene.id == id }
            guard let value, let type = scene.valueType else { return false }
            return Swift.type(of: value.base) == type
        }
        guard let index else { return }
        if let existing = openWindows.first(where: { $0.window != nil && $0.sceneIndex == index && (scenes[index].isSingle || ($0.value == value && value != nil)) })?.window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        makeWindow(sceneIndex: index, value: value)
    }

    static func dismiss(id: String?, value: AnyHashable?) {
        for entry in openWindows {
            guard let window = entry.window else { continue }
            let scene = scenes[entry.sceneIndex]
            let idMatches = id.map { scene.id == $0 } ?? true
            let valueMatches = value.map { entry.value == $0 } ?? true
            if idMatches && valueMatches { window.close() }
        }
    }

    @discardableResult
    static func makeWindow(sceneIndex: Int, value: AnyHashable?) -> NSWindow {
        let description = scenes[sceneIndex]
        let host = GraphHostingView(makeGraph: { backend in description.makeGraphForValue(backend, value) })
        let window = makeNativeWindow(for: description)
        window.isReleasedWhenClosed = false
        window.title = description.title.isEmpty ? ProcessInfo.processInfo.processName : description.title
        let baseTitle = window.title
        host.graph.onNavigationTitleChange = { [weak window] title in
            window?.title = title ?? baseTitle
        }
        host.graph.onNavigationSubtitleChange = { [weak window] subtitle in
            window?.subtitle = subtitle ?? ""
        }
        host.graph.setEnvironment { environment in
            environment.dismissWindow = DismissWindowAction(_current: { [weak window] in window?.close() })
        }
        window.contentView = host
        window.initialFirstResponder = host
        let sceneResizable = window.styleMask.contains(.resizable)
        host.graph.onWindowConfigurationChange = { [weak window, weak host] configuration in
            guard let window, let host else { return }
            AppKitAppRunner.apply(configuration, to: window, host: host, sceneResizable: sceneResizable)
        }
        let toolbarController = WindowToolbarController(window: window, host: host)
        toolbarControllers.append(toolbarController)
        host.graph.onToolbarChange = { [weak toolbarController] toolbar in toolbarController?.update(toolbar) }
        // Like SwiftUI: the content's minimum size bounds the window, and the default frame is
        // `defaultSize`, else 900x450 (title bar included) grown to the minimum size; the ideal
        // size is not used (a tall scroll view opens in a 900x450 window).
        let minimum = host.sizeThatFits(ProposedViewSize(width: 0, height: 0))
        window.contentMinSize = minimum
        if description.resizability == .contentSize {
            // The window can't grow beyond the content's maximum size.
            let maximum = host.sizeThatFits(ProposedViewSize(width: .infinity, height: .infinity))
            window.contentMaxSize = CGSize(width: maximum.width.isFinite ? maximum.width : CGFloat.greatestFiniteMagnitude,
                                           height: maximum.height.isFinite ? maximum.height : CGFloat.greatestFiniteMagnitude)
        }
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let frameSize: CGSize
        if let size = description.defaultSize {
            frameSize = size
        } else if description.kind == .utility || description.resizability == .contentSize {
            // Panels and content-sized windows fit their content.
            let ideal = host.sizeThatFits(.unspecified)
            frameSize = CGSize(width: ideal.width, height: ideal.height + titleBar)
        } else {
            frameSize = CGSize(width: max(minimum.width, 900), height: max(minimum.height + titleBar, 450))
        }
        // Centered in the screen's visible frame (NSWindow.center() places windows higher);
        // further windows cascade.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let cascade = CGFloat(openWindows.filter { $0.window?.isVisible == true }.count) * 22
        var origin = CGPoint(x: (visible.midX - frameSize.width / 2).rounded() + cascade, y: (visible.midY - frameSize.height / 2).rounded() - cascade)
        if let position = description.defaultPosition {
            // defaultPosition: a unit point of the visible frame (top-left origin).
            origin = CGPoint(x: (visible.minX + (visible.width - frameSize.width) * position.x).rounded(),
                             y: (visible.maxY - frameSize.height - (visible.height - frameSize.height) * position.y).rounded())
        }
        window.setFrame(CGRect(origin: origin, size: frameSize), display: false)
        // SwiftUI restores window frames between launches.
        let autosaveName = "SwiftUI2.WindowGroup-\(description.id ?? description.title)-\(value.map { "\($0)" } ?? "1")"
        window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        configureDocumentWindow(window, value: value, baseTitle: baseTitle)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        openWindows.removeAll { $0.window == nil }
        openWindows.append(OpenWindow(window: window, sceneIndex: sceneIndex, value: value))
        return window
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        var settings: WindowDescription?
        private var settingsWindow: NSWindow?

        // SwiftUI keeps WindowGroup apps running when the last window closes.
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            MainActor.assumeIsolated {
                AppKitAppRunner.userDelegate?.applicationShouldTerminateAfterLastWindowClosed?(sender) ?? false
            }
        }

        /// URLs opened in the app (custom schemes, Open With): `onOpenURL` handlers first.
        func application(_ application: NSApplication, open urls: [URL]) {
            MainActor.assumeIsolated {
                if AppRuntime.handleOpenURLs(urls) { return }
                AppKitAppRunner.userDelegate?.application?(application, open: urls)
            }
        }

        /// Handoff / Spotlight activities: `onContinueUserActivity` handlers first.
        func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
            MainActor.assumeIsolated {
                if AppRuntime.continueUserActivity(userActivity) { return true }
                return AppKitAppRunner.userDelegate?.application?(application, continue: userActivity, restorationHandler: restorationHandler) ?? false
            }
        }

        func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
            MainActor.assumeIsolated { AppRuntime.handlesUserActivity(type: userActivityType) }
        }

        /// Dock icon click with no windows: reopen the main window (like SwiftUI).
        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            MainActor.assumeIsolated {
                if let custom = AppKitAppRunner.userDelegate?.applicationShouldHandleReopen?(sender, hasVisibleWindows: flag) { return custom }
                if !flag, let first = AppKitAppRunner.scenes.firstIndex(where: { $0.opensAtLaunch }) {
                    AppKitAppRunner.makeWindow(sceneIndex: first, value: nil)
                }
                return true
            }
        }

        @MainActor @objc func newWindow(_ sender: Any?) {
            if let first = AppKitAppRunner.scenes.firstIndex(where: { $0.opensAtLaunch }) {
                AppKitAppRunner.makeWindow(sceneIndex: first, value: nil)
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

/// Implements a responder-chain action selector by forwarding it to the view graph. Methods are
/// added to the class on first use, one per selector.
final class CommandTrampoline: NSObject {
    weak var graph: ViewGraph?
    let selectorName: String

    private init(selectorName: String) { self.selectorName = selectorName }

    @MainActor private static var added: Set<String> = []

    @MainActor
    static func target(for action: Selector, graph: ViewGraph) -> CommandTrampoline {
        let name = NSStringFromSelector(action)
        if !added.contains(name) {
            added.insert(name)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { object, _ in
                guard let trampoline = object as? CommandTrampoline else { return }
                MainActor.assumeIsolated { _ = trampoline.graph?.handleCommand(trampoline.selectorName) }
            }
            class_addMethod(CommandTrampoline.self, action, imp_implementationWithBlock(block), "v@:@")
        }
        let trampoline = CommandTrampoline(selectorName: name)
        trampoline.graph = graph
        return trampoline
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
