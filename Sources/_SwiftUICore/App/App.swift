import Foundation
import Observation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Mirrors `SwiftUI.App`. `main()` is provided by the `SwiftUI` umbrella module, which forwards to
/// the platform backend registered in `AppRuntime`.
@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }
    init()
}

@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    /// Flattens the scene into window descriptions for the backend.
    func _collectWindows(into windows: inout [WindowDescription])
    /// Menu bar commands attached with `.commands`.
    func _collectCommands(into commands: inout [any Commands])
}

extension Scene {
    public func _collectWindows(into windows: inout [WindowDescription]) {
        body._collectWindows(into: &windows)
    }
    public func _collectCommands(into commands: inout [any Commands]) {
        body._collectCommands(into: &commands)
    }
}

extension Never: Scene {
    public func _collectWindows(into windows: inout [WindowDescription]) {}
    public func _collectCommands(into commands: inout [any Commands]) {}
}

/// Platform-independent description of a window a backend should open.
@MainActor
public struct WindowDescription {
    public enum Role: Sendable { case main, settings }
    public let title: String
    public let defaultSize: CGSize?
    public var role: Role = .main
    /// `WindowGroup(id:)` / `Window(_:id:)` identifier (for `openWindow(id:)`).
    public var id: String?
    /// Presenting values (`WindowGroup(for:)`): windows open only through `openWindow(value:)`.
    public var valueType: Any.Type?
    /// A single-instance window (`Window`).
    public var isSingle = false
    private let buildGraph: @MainActor (any RenderBackend, AnyHashable?) -> ViewGraph
    /// Scene-level environment (`Scene.environment`, `Scene.modelContainer`), applied in order.
    public var environmentTransforms: [@MainActor (inout EnvironmentValues) -> Void] = []

    public init(title: String, defaultSize: CGSize?, makeGraph: @escaping @MainActor (any RenderBackend, AnyHashable?) -> ViewGraph) {
        self.title = title
        self.defaultSize = defaultSize
        self.buildGraph = makeGraph
    }

    /// Builds the window's view graph on the given backend (`value`: the presented value).
    public var makeGraphForValue: @MainActor (any RenderBackend, AnyHashable?) -> ViewGraph {
        let build = buildGraph
        let transforms = environmentTransforms
        return { backend, value in
            let graph = build(backend, value)
            if !transforms.isEmpty {
                graph.setEnvironment { values in
                    for transform in transforms { transform(&values) }
                }
            }
            return graph
        }
    }

    public init(title: String, defaultSize: CGSize?, makeGraph: @escaping @MainActor (any RenderBackend) -> ViewGraph) {
        self.init(title: title, defaultSize: defaultSize, makeGraph: { backend, _ in makeGraph(backend) })
    }

    /// Builds the window's view graph (no presented value).
    public var makeGraph: @MainActor (any RenderBackend) -> ViewGraph { { makeGraphForValue($0, nil) } }

    /// Opens at launch (the first plain window group / window).
    public var opensAtLaunch: Bool { role == .main && valueType == nil && launchBehavior != .suppressed && kind == .standard }

    /// Window chrome (`windowStyle`, `UtilityWindow`).
    public var kind: WindowKind = .standard
    public var resizability = WindowResizability.automatic
    /// Initial position in the screen's visible frame (`defaultPosition`).
    public var defaultPosition: UnitPoint?
    public var toolbarStyle = WindowToolbarStyleKind.automatic
    public var launchBehavior = SceneLaunchBehavior.automatic
    public var level = WindowLevel.automatic
    /// A status item instead of a window (`MenuBarExtra`).
    public var menuBarExtra: MenuBarExtraDescription?
    /// Document windows (`DocumentGroup`).
    public var document: DocumentSceneDescription?
}

public enum WindowKind: Hashable, Sendable { case standard, hiddenTitleBar, plain, utility }

public struct WindowGroup<Content: View>: Scene {
    let title: String
    let id: String?
    /// Makes a window's content from its presented value, once per window.
    let content: (AnyHashable?) -> () -> Content
    let valueType: Any.Type?
    var defaultSize: CGSize?

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.id = nil
        self.content = { _ in content }
        self.valueType = nil
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.id = nil
        self.content = { _ in content }
        self.valueType = nil
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = titleKey.key
        self.id = nil
        self.content = { _ in content }
        self.valueType = nil
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.id = id
        self.content = { _ in content }
        self.valueType = nil
    }

    public init(id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.id = id
        self.content = { _ in content }
        self.valueType = nil
    }

    /// Windows presenting a value (opened with `openWindow(value:)` / `openWindow(id:value:)`).
    @_disfavoredOverload public init<S: StringProtocol, D: Codable & Hashable>(_ title: S, id: String? = nil, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> Content) {
        self.title = String(title)
        self.id = id
        self.valueType = D.self
        self.content = { value in
            // One box per window: its binding outlives body updates, and setting it updates the window.
            let box = _WindowValueBox(value: value?.base as? D)
            return { content(Binding(get: { box.value }, set: { box.value = $0 })) }
        }
    }

    public init<D: Codable & Hashable>(id: String? = nil, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> Content) {
        self.init("", id: id, for: type, content: content)
    }

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        var description = WindowDescription(title: title, defaultSize: defaultSize) { backend, value in
            // Evaluated inside a body so reads in the scene's content closure are tracked.
            ViewGraph(rootView: _WindowContent(content: content(value)), backend: backend)
        }
        description.id = id
        description.valueType = valueType
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}

    public func defaultSize(width: CGFloat, height: CGFloat) -> WindowGroup {
        var copy = self
        copy.defaultSize = CGSize(width: width, height: height)
        return copy
    }
}

/// A window's presented value (`WindowGroup(for:)`), observed by the window's views.
@MainActor @Observable
final class _WindowValueBox<D> {
    var value: D?
    init(value: D?) { self.value = value }
}

/// A single window (`Window(_:id:)`).
public struct Window<Content: View>: Scene {
    let title: String
    let id: String
    let content: () -> Content
    var defaultSize: CGSize?

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.id = id
        self.content = content
    }

    public init(_ titleKey: LocalizedStringKey, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(titleKey.key, id: id, content: content)
    }

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        var description = WindowDescription(title: title, defaultSize: defaultSize) { backend in
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        }
        description.id = id
        description.isSingle = true
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}

    public func defaultSize(width: CGFloat, height: CGFloat) -> Window {
        var copy = self
        copy.defaultSize = CGSize(width: width, height: height)
        return copy
    }
}

struct _WindowContent<Content: View>: View {
    let content: () -> Content
    var body: Content { content() }
}

/// The app's settings window (opened from the application menu).
public struct Settings<Content: View>: Scene {
    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        var description = WindowDescription(title: "Settings", defaultSize: nil) { backend in
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        }
        description.role = .settings
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}
}

extension Scene {
    public func commands<C: Commands>(@CommandsBuilder content: () -> C) -> some Scene {
        _CommandsScene(base: self, commands: content())
    }
    public func commandsRemoved() -> some Scene { self }
    public func commandsReplaced<C: Commands>(@CommandsBuilder content: () -> C) -> some Scene {
        _CommandsScene(base: self, commands: content())
    }
}

/// How a window's size follows its content.
public struct WindowResizability: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case automatic, contentSize, contentMinSize }
    let kind: Kind
    public static let automatic = WindowResizability(kind: .automatic)
    /// The window can't be resized beyond the content's min/max sizes.
    public static let contentSize = WindowResizability(kind: .contentSize)
    /// The content's minimum size is the window's minimum.
    public static let contentMinSize = WindowResizability(kind: .contentMinSize)
}

public struct _TupleScene<each S: Scene>: Scene {
    let scenes: (repeat each S)
    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        for scene in repeat each scenes {
            scene._collectWindows(into: &windows)
        }
    }

    public func _collectCommands(into commands: inout [any Commands]) {
        for scene in repeat each scenes {
            scene._collectCommands(into: &commands)
        }
    }
}

public struct _CommandsScene<Base: Scene, C: Commands>: Scene {
    let base: Base
    let commands: C
    public var body: Never { fatalError() }
    public func _collectWindows(into windows: inout [WindowDescription]) { base._collectWindows(into: &windows) }
    public func _collectCommands(into commands: inout [any Commands]) {
        base._collectCommands(into: &commands)
        commands.append(self.commands)
    }
}

@resultBuilder @MainActor
public enum SceneBuilder {
    public static func buildBlock<S: Scene>(_ scene: S) -> S { scene }
    public static func buildBlock<each S: Scene>(_ scenes: repeat each S) -> _TupleScene<repeat each S> {
        _TupleScene(scenes: (repeat each scenes))
    }
}

/// Registry the umbrella module uses to run an `App` on the current platform's backend.
@MainActor
public enum AppRuntime {
    public static var runner: ((_ windows: [WindowDescription]) -> Never)?
    /// Opens a window for an id and/or value (installed by the backend runner).
    public static var openWindow: (@MainActor (String?, AnyHashable?) -> Void)?
    public static var dismissWindow: (@MainActor (String?, AnyHashable?) -> Void)?
    /// Opens a window from code, outside the scenes (`HostingWindow`), and calls `onClose` once it closes;
    /// returns the backend's handle for it (installed by backends that run windows).
    public static var presentWindow: (@MainActor (_ window: WindowDescription, _ onClose: @escaping @MainActor () -> Void) -> AnyObject?)?
    /// Brings a presented window to the front.
    public static var focusPresentedWindow: (@MainActor (AnyObject) -> Void)?
    /// Closes a presented window.
    public static var closePresentedWindow: (@MainActor (AnyObject) -> Void)?
    /// Starts moving the window under the pointer with the current mouse-down (`WindowDragGesture`).
    public static var performWindowDrag: (@MainActor () -> Void)?
    /// The app's menu bar commands (evaluated by backends when menus open).
    public static var commands: [any Commands] = []
    /// Environment seen by commands (color scheme, ...).
    public static var environment = EnvironmentValues()

    /// Current command entries (evaluates the commands' bodies).
    public static func commandEntries() -> [CommandEntry] {
        var entries: [CommandEntry] = []
        for command in commands { command._commandEntries(into: &entries) }
        return entries
    }

    public static func run<A: App>(_ type: A.Type) -> Never {
        let windows = prepare(type)
        guard let runner else {
            fatalError("No SwiftUI backend registered for this platform")
        }
        runner(windows)
    }

    /// Creates the app and collects its scenes and commands, for platforms whose main loop is
    /// owned by the system (Android: `App.main()` returns and the activity creates windows).
    public static func prepare<A: App>(_ type: A.Type) -> [WindowDescription] {
        let app = A()
        self.app = app
        var windows: [WindowDescription] = []
        app.body._collectWindows(into: &windows)
        var collected: [any Commands] = []
        app.body._collectCommands(into: &collected)
        commands = collected
        return windows
    }

    /// The running app (kept alive for platforms where `main` returns).
    public private(set) static var app: (any App)?
}

/// A window code opens itself, with a view in it, outside the app's scenes: what an `NSWindow` with an
/// `NSHostingView` is on the Mac, on every backend (for libraries that show a window of their own, such as an
/// updater's). Showing it again brings it to the front.
///
/// ```swift
/// let window = HostingWindow(title: "Software Update", defaultSize: CGSize(width: 560, height: 200)) {
///     UpdateView(updater: updater)
/// }
/// window.onClose = { updater.windowClosed() }
/// window.show()
/// ```
@MainActor
public final class HostingWindow {
    public let title: String
    /// Called once the window closed (by the user or `close()`).
    public var onClose: (() -> Void)?
    private let description: WindowDescription
    private var handle: AnyObject?

    public init<Content: View>(title: String, defaultSize: CGSize? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        var description = WindowDescription(title: title, defaultSize: defaultSize) { backend in
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        }
        description.launchBehavior = .suppressed
        self.description = description
    }

    /// Whether the window is open.
    public var isVisible: Bool { handle != nil }

    /// Opens the window, or brings it to the front.
    public func show() {
        if let handle {
            AppRuntime.focusPresentedWindow?(handle)
            return
        }
        handle = AppRuntime.presentWindow?(description) { [weak self] in
            guard let self else { return }
            self.handle = nil
            self.onClose?()
        }
    }

    public func close() {
        if let handle { AppRuntime.closePresentedWindow?(handle) }
    }
}
