import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Hosts one view hierarchy: owns the attribute graph, the render tree and the backend.
/// Backends (AppKit hosting view, headless test host, GTK window, ...) drive it with
/// `setProposedSize`, `update()` and by scheduling updates when `onNeedsUpdate` fires.
@MainActor
public final class ViewGraph: AttributeGraphDelegate {
    public let graph = AttributeGraph()
    public let tracer = UpdateTracer()
    public let renderer: Renderer
    /// Hover for every backend: hosts feed it the pointer (see `HoverTracker`).
    public private(set) var hoverTracker: HoverTracker!
    let rootSubgraph: Subgraph
    private let proposal: Attribute<ProposedViewSize>
    private let environment: Attribute<EnvironmentValues>
    private var rootOutputs: _ViewOutputs!
    private(set) var presentations: PresentationRegistry!
    private var layerOutputs: _ViewOutputs?
    private(set) var rootGeometry: Attribute<ViewGeometry>!
    private var setRoot: ((Any) -> Void)?
    private var afterUpdate: [@MainActor () -> Void] = []
    private var isTornDown = false
    /// An update (or animation frame) is running.
    public private(set) var isUpdating = false

    // MARK: Transactions & animation state
    private var pendingTransaction = Transaction()
    /// Root transaction of the update in progress.
    private(set) var currentTransaction = Transaction()
    /// Incremented once per update pass (used by `.animation(_:value:)` change detection).
    private(set) var updateSequence = 0
    /// Time source for animations (seconds). Hosts may replace it (tests use a manual clock).
    public var clock: () -> Double = { ProcessInfo.processInfo.systemUptime } {
        didSet {
            renderer.clock = clock
            hoverTracker.clock = clock
        }
    }
    var now: Double { clock() }
    /// Source attribute advanced on every animation frame while `Animatable` values interpolate.
    private(set) var animationTime: Attribute<Double>!
    /// `focusedValue` registrations and the focused view (see `FocusedValuesCenter`).
    let focusedValueRegistry = FocusedValueRegistry()
    /// `onModifierKeysChanged` registrations and the last reported modifier keys.
    var modifierKeysObservers: [ObjectIdentifier: ModifierKeysObserver] = [:]
    var currentModifierFlags: EventModifiers = []
    private var activeAnimators = 0

    /// Called when animations need display-synchronized frames; the host should call
    /// `renderAnimationFrame()` once per display refresh until `hasActiveAnimations` is false.
    public var onNeedsAnimationFrame: (() -> Void)?
    public var hasActiveAnimations: Bool { activeAnimators > 0 || renderer.hasActiveAnimations }

    func animatorStarted() { activeAnimators += 1 }
    func animatorStopped() { activeAnimators = max(0, activeAnimators - 1) }

    /// Called when the graph has pending work; the host should call `update()` soon (e.g. before
    /// the run loop sleeps). Not called for changes made during `update()`.
    public var onNeedsUpdate: (() -> Void)?

    public init<Root: View>(rootView: Root, backend: any RenderBackend, environment: EnvironmentValues = EnvironmentValues(), proposedSize: ProposedViewSize = .unspecified) {
        rootSubgraph = Subgraph(graph: graph)
        renderer = Renderer(backend: backend, tracer: tracer)
        let clock = self.clock
        hoverTracker = HoverTracker(renderer: renderer, tracer: tracer, clock: clock)
        renderer.onContentChange = { [unowned hoverTracker] in hoverTracker!.contentChanged() }
        proposal = Attribute(rootSubgraph, value: proposedSize, isEqual: { $0 == $1 })
        var rootEnvironment = environment
        rootEnvironment.openURL = OpenURLAction { [weak backend] url in backend?.openURL(url) }
        rootEnvironment._share = ShareAction { [weak backend] items in backend?.share(items) }
        rootEnvironment._pasteboard = PasteboardWriter { [weak backend] items in backend?.writeToPasteboard(items) }
        Pasteboard.general.backend = backend
        rootEnvironment._haptics = HapticPerformer { [weak backend] feedback in backend?.performHapticFeedback(feedback) }
        #if canImport(UniformTypeIdentifiers)
        rootEnvironment._pasteboardReader = PasteboardReader { [weak backend] in backend?.readPasteboard() ?? [] }
        #endif
        rootEnvironment._imageDecoder = ImageDecoder { [weak backend] data, scale in
            backend?.decodeImage(data, scale: scale).map { Image(_platformImage: $0) }
        }
        rootEnvironment._fileDialogs = FileDialogPresenter { [weak backend] request, completion in
            if let backend { backend.presentFileDialog(request, completion: completion) } else { completion(nil) }
        }
        self.environment = Attribute(rootSubgraph, value: rootEnvironment)
        graph.delegate = self
        animationTime = Attribute(rootSubgraph, value: 0, isEqual: { $0 == $1 })
        graph.willChangeSource = { [unowned self] in
            if !Transaction.current.isEmpty { pendingTransaction.merge(Transaction.current) }
        }

        let root = Attribute<Root>(rootSubgraph, value: rootView)
        root.label = "root view"
        setRoot = { value in root.setValue(value as! Root) }

        let geometry = Attribute<ViewGeometry>(rootSubgraph, isEqual: { $0 == $1 })
        geometry.label = "root geometry"
        rootGeometry = geometry
        let inputs = _ViewInputs(
            host: self,
            subgraph: rootSubgraph,
            environment: self.environment,
            geometry: geometry,
            render: _RenderInputs(parent: renderer.root, origin: nil),
            depth: 0,
            path: ViewPath(typeName(Root.self)),
            stackAxis: nil,
            modifierContent: nil
        )
        presentations = PresentationRegistry(subgraph: rootSubgraph)
        rootOutputs = Root._makeView(view: _GraphValue(root), inputs: inputs.requesting(NavigationTitleKey.self).requesting(NavigationSubtitleKey.self).requesting(ToolbarItemsKey.self).requesting(NavigationChromeKey.self).requesting(WindowConfigurationKey.self))
        let titleAttribute = rootOutputs.preferences.attribute(for: NavigationTitleKey.self, in: rootSubgraph)
        let titleObserver = Attribute<String?>(rootSubgraph, isEqual: { $0 == $1 }) { titleAttribute?.value?.plainString }
        titleObserver.onChange = { [unowned self] title in
            enqueueAfterUpdate { [unowned self] in navigationTitle = title }
        }
        titleObserver.isEager = true

        let subtitleAttribute = rootOutputs.preferences.attribute(for: NavigationSubtitleKey.self, in: rootSubgraph)
        let subtitleObserver = Attribute<String?>(rootSubgraph, isEqual: { $0 == $1 }) { subtitleAttribute?.value }
        subtitleObserver.onChange = { [unowned self] subtitle in
            enqueueAfterUpdate { [unowned self] in navigationSubtitle = subtitle }
        }
        subtitleObserver.isEager = true

        // Window toolbar (items from `.toolbar`, chrome from navigation containers).
        let itemsAttribute = rootOutputs.preferences.attribute(for: ToolbarItemsKey.self, in: rootSubgraph)
        let chromeAttribute = rootOutputs.preferences.attribute(for: NavigationChromeKey.self, in: rootSubgraph)
        let toolbarObserver = Attribute<WindowToolbar>(rootSubgraph, isEqual: { $0 == $1 }) {
            WindowToolbar(items: itemsAttribute?.value ?? [], chrome: chromeAttribute?.value ?? NavigationChrome())
        }
        toolbarObserver.onChange = { [unowned self] toolbar in
            enqueueAfterUpdate { [unowned self] in windowToolbar = toolbar }
        }
        toolbarObserver.isEager = true

        // Window behavior set by views (`windowResizeBehavior`, `navigationDocument`, ...).
        let windowAttribute = rootOutputs.preferences.attribute(for: WindowConfigurationKey.self, in: rootSubgraph)
        let windowObserver = Attribute<WindowConfiguration>(rootSubgraph, isEqual: { $0 == $1 }) { windowAttribute?.value ?? WindowConfiguration() }
        windowObserver.onChange = { [unowned self] configuration in
            enqueueAfterUpdate { [unowned self] in windowConfiguration = configuration }
        }
        windowObserver.isEager = true

        // Presentation layer (sheets, alerts, popovers, menus) above the root, covering the window.
        let layerGeometry = Attribute<ViewGeometry>(rootSubgraph, isEqual: { $0 == $1 })
        var layerInputs = inputs
        layerInputs.geometry = layerGeometry
        layerInputs.path = ViewPath("PresentationLayer")
        let layer = _PresentationLayer._makeView(view: _GraphValue(Attribute(rootSubgraph, value: _PresentationLayer())), inputs: layerInputs)
        layerOutputs = layer
        let layout = rootOutputs.layout
        let proposal = self.proposal
        let rootLayoutForLayer = layout
        layerGeometry.setRule {
            let proposed = proposal.value
            let size = proposed.replacingUnspecifiedDimensions(by: rootLayoutForLayer.value.sizeThatFits(proposed))
            return ViewGeometry(origin: .zero, size: size, proposal: ProposedViewSize(size))
        }
        geometry.setRule {
            let proposed = proposal.value
            let size = layout.value.sizeThatFits(proposed)
            // Like NSHostingView, the root is centered in the space it was offered.
            let container = proposed.replacingUnspecifiedDimensions(by: size)
            return ViewGeometry(
                origin: CGPoint(x: ((container.width - size.width) / 2).rounded(), y: ((container.height - size.height) / 2).rounded()),
                size: size,
                proposal: proposed
            )
        }
    }

    public func setRootView<Root: View>(_ rootView: Root) {
        setRoot?(rootView)
    }

    /// The size the host currently offers the root view.
    public var proposedSize: ProposedViewSize { proposal.peekValue ?? .unspecified }

    public func setProposedSize(_ size: ProposedViewSize) {
        proposal.setValue(size)
    }

    public func setEnvironment(_ transform: (inout EnvironmentValues) -> Void) {
        var values = environment.peekValue ?? EnvironmentValues()
        transform(&values)
        environment.setValue(values)
    }

    /// The root view's size for a proposal (does not affect the current layout).
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        AnyAttribute.withoutDependencies { rootOutputs.layout.value.sizeThatFits(proposal) }
    }

    public var rootFrame: CGRect { AnyAttribute.withoutDependencies { rootGeometry.value.frame } }

    public var needsUpdate: Bool { graph.hasPendingUpdates || renderer.hasPendingChanges || !afterUpdate.isEmpty }

    /// Brings the graph up to date, commits render changes, then runs deferred actions
    /// (onAppear, onChange, ...). Repeats while actions caused further changes.
    public func update() {
        // Never re-entered: a platform callback during a commit (AppKit resizing the host in the
        // layout pass of the commit's Core Animation transaction) asks for the next turn instead.
        if isUpdating {
            onNeedsUpdate?()
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        guard !isTornDown else { return }
        var passes = 0
        renderer.schedule = { [unowned self] action in afterUpdate.append(action) }
        repeat {
            currentTransaction = pendingTransaction
            pendingTransaction = Transaction()
            updateSequence += 1
            renderer.transaction = currentTransaction
            graph.update()
            renderer.commit()
            currentTransaction = Transaction()
            renderer.transaction = Transaction()
            let actions = afterUpdate
            afterUpdate.removeAll()
            AnyAttribute.withoutDependencies {
                for action in actions { action() }
            }
            passes += 1
        } while (graph.hasPendingUpdates || !afterUpdate.isEmpty) && passes < 16
        if passes == 16 {
            runtimeWarning("View graph did not settle after 16 passes; an onChange/onAppear handler is probably updating state every time.")
        }
        if hasActiveAnimations { onNeedsAnimationFrame?() }
    }

    /// Advances animations to `clock()`: re-evaluates `Animatable` views and interpolates render
    /// properties. Call once per display frame while `hasActiveAnimations`.
    public func renderAnimationFrame() {
        guard !isTornDown else { return }
        guard !isUpdating else { return }
        let time = now
        if activeAnimators > 0 {
            // State changed by events since the last update (e.g. a hover) is applied in its own
            // update first, in its own transaction; advancing animators must not run inside that
            // transaction, or their per-frame values would be animated again by the renderer.
            if graph.hasPendingUpdates { update() }
            animationTime.setValue(time)
            update()
        }
        isUpdating = true
        renderer.tick(at: time)
        isUpdating = false
        let actions = afterUpdate
        afterUpdate.removeAll()
        if !actions.isEmpty {
            AnyAttribute.withoutDependencies { for action in actions { action() } }
            if needsUpdate { update() }
        }
    }

    func enqueueAfterUpdate(_ action: @escaping @MainActor () -> Void) {
        afterUpdate.append(action)
        onNeedsUpdate?()
    }

    public func graphNeedsUpdate(_ graph: AttributeGraph) {
        onNeedsUpdate?()
    }

    /// Called with the root's `.navigationTitle` (hosts use it for the window title). Setting it
    /// immediately delivers the current title.
    public var onNavigationTitleChange: ((String?) -> Void)? {
        didSet { onNavigationTitleChange?(navigationTitle) }
    }

    /// Called with the window toolbar (items and navigation chrome) whenever it changes; setting
    /// it delivers the current toolbar.
    public var onToolbarChange: ((WindowToolbar) -> Void)? {
        didSet { onToolbarChange?(windowToolbar) }
    }

    public private(set) var windowToolbar = WindowToolbar() {
        didSet { if windowToolbar != oldValue { onToolbarChange?(windowToolbar) } }
    }

    /// Called when views change window behavior (resizing, represented document, background, ...).
    public var onWindowConfigurationChange: ((WindowConfiguration) -> Void)? {
        didSet { onWindowConfigurationChange?(windowConfiguration) }
    }

    public private(set) var windowConfiguration = WindowConfiguration() {
        didSet { if windowConfiguration != oldValue { onWindowConfigurationChange?(windowConfiguration) } }
    }

    /// Called with the root's `.navigationSubtitle` (the window subtitle).
    public var onNavigationSubtitleChange: ((String?) -> Void)? {
        didSet { onNavigationSubtitleChange?(navigationSubtitle) }
    }

    public private(set) var navigationSubtitle: String? {
        didSet { if navigationSubtitle != oldValue { onNavigationSubtitleChange?(navigationSubtitle) } }
    }

    /// The root's current `.navigationTitle`.
    public private(set) var navigationTitle: String? {
        didSet { if navigationTitle != oldValue { onNavigationTitleChange?(navigationTitle) } }
    }

    /// Dismisses the top-most presentation (Escape key). Returns true if one was dismissed.
    @discardableResult
    public func dismissTopPresentation() -> Bool {
        guard let top = presentations.top else { return false }
        top.interactiveDismiss()
        return true
    }

    /// Finds a control with a matching keyboard shortcut and triggers it. Returns true if handled.
    @discardableResult
    public func performKeyboardShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        func visit(_ node: RenderNode) -> Bool {
            if node.actions.keyboardShortcut == shortcut, let action = node.actions.primary {
                action()
                return true
            }
            for child in node.children where visit(child) { return true }
            return false
        }
        return visit(renderer.root)
    }

    /// Routes a key press to `onKeyPress` handlers, innermost (last in tree order) first. Returns
    /// true if a handler handled it.
    @discardableResult
    public func handleKeyPress(_ press: KeyPress) -> Bool {
        var handlers: [@MainActor (KeyPress) -> KeyPress.Result] = []
        func visit(_ node: RenderNode) {
            if let handler = node.actions.keyPress { handlers.append(handler) }
            for child in node.children { visit(child) }
        }
        visit(renderer.root)
        for handler in handlers.reversed() where handler(press) == .handled { return true }
        return false
    }

    /// Edit > Paste: offers the providers to the innermost `onPasteCommand` handler.
    @discardableResult
    public func handlePaste(_ providers: [AnyObject], types: [String]) -> Bool {
        var handler: (@MainActor ([AnyObject]) -> Void)?
        func visit(_ node: RenderNode) {
            if let paste = node.actions.paste, !Set(node.actions.pasteTypes).isDisjoint(with: types) { handler = paste }
            for child in node.children { visit(child) }
        }
        visit(renderer.root)
        guard let handler else { return false }
        handler(providers)
        return true
    }

    /// Destroys the hierarchy (runs onDisappear, removes platform views).
    public func tearDown() {
        guard !isTornDown else { return }
        rootSubgraph.destroy()
        renderer.commit()
        isTornDown = true
        let actions = afterUpdate
        afterUpdate.removeAll()
        AnyAttribute.withoutDependencies {
            for action in actions { action() } // onDisappear
        }
    }
}
