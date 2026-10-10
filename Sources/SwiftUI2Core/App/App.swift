import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Mirrors `SwiftUI.App`. `main()` is provided by the `SwiftUI2` umbrella module, which forwards to
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
    /// Builds the window's view graph on the given backend (`value`: the presented value).
    public let makeGraphForValue: @MainActor (any RenderBackend, AnyHashable?) -> ViewGraph

    public init(title: String, defaultSize: CGSize?, makeGraph: @escaping @MainActor (any RenderBackend, AnyHashable?) -> ViewGraph) {
        self.title = title
        self.defaultSize = defaultSize
        self.makeGraphForValue = makeGraph
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
    let content: (AnyHashable?) -> Content
    let valueType: Any.Type?
    var defaultSize: CGSize?

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.id = nil
        self.content = { _ in content() }
        self.valueType = nil
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.id = nil
        self.content = { _ in content() }
        self.valueType = nil
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = titleKey.key
        self.id = nil
        self.content = { _ in content() }
        self.valueType = nil
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.id = id
        self.content = { _ in content() }
        self.valueType = nil
    }

    public init(id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.id = id
        self.content = { _ in content() }
        self.valueType = nil
    }

    /// Windows presenting a value (opened with `openWindow(value:)` / `openWindow(id:value:)`).
    @_disfavoredOverload public init<S: StringProtocol, D: Codable & Hashable>(_ title: S, id: String? = nil, for type: D.Type, @ViewBuilder content: @escaping (Binding<D?>) -> Content) {
        self.title = String(title)
        self.id = id
        self.valueType = D.self
        self.content = { value in
            let box = _WindowValueBox(value: value?.base as? D)
            return content(Binding(get: { box.value }, set: { box.value = $0 }))
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
            ViewGraph(rootView: _WindowContent(content: { content(value) }), backend: backend)
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

/// A window's presented value (`WindowGroup(for:)`).
@MainActor
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
        let app = A()
        var windows: [WindowDescription] = []
        app.body._collectWindows(into: &windows)
        var collected: [any Commands] = []
        app.body._collectCommands(into: &collected)
        commands = collected
        guard let runner else {
            fatalError("No SwiftUI2 backend registered for this platform")
        }
        runner(windows)
    }
}
