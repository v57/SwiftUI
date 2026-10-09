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
}

extension Scene {
    public func _collectWindows(into windows: inout [WindowDescription]) {
        body._collectWindows(into: &windows)
    }
}

extension Never: Scene {}

/// Platform-independent description of a window a backend should open.
@MainActor
public struct WindowDescription {
    public enum Role: Sendable { case main, settings }
    public let title: String
    public let defaultSize: CGSize?
    public var role: Role = .main
    /// Builds the window's view graph on the given backend.
    public let makeGraph: @MainActor (any RenderBackend) -> ViewGraph
}

public struct WindowGroup<Content: View>: Scene {
    let title: String
    let content: () -> Content
    var defaultSize: CGSize?

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.title = ""
        self.content = content
    }

    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(title)
        self.content = content
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = titleKey.key
        self.content = content
    }

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        windows.append(WindowDescription(title: title, defaultSize: defaultSize) { backend in
            // Evaluated inside a body so reads in the scene's content closure are tracked.
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        })
    }

    public func defaultSize(width: CGFloat, height: CGFloat) -> WindowGroup {
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
}

extension Scene {
    public func windowResizability(_ resizability: WindowResizability) -> some Scene { self }
    public func windowStyle<S>(_ style: S) -> some Scene { self }
    public func commands<C: Commands>(@CommandsBuilder content: () -> C) -> some Scene { self }
    public func defaultPosition(_ position: UnitPoint) -> some Scene { self }
    public func windowToolbarStyle<S>(_ style: S) -> some Scene { self }
}

public struct WindowResizability: Sendable {
    public static let automatic = WindowResizability()
    public static let contentSize = WindowResizability()
    public static let contentMinSize = WindowResizability()
}

public struct _TupleScene<each S: Scene>: Scene {
    let scenes: (repeat each S)
    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        for scene in repeat each scenes {
            scene._collectWindows(into: &windows)
        }
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

    public static func run<A: App>(_ type: A.Type) -> Never {
        let app = A()
        var windows: [WindowDescription] = []
        app.body._collectWindows(into: &windows)
        guard let runner else {
            fatalError("No SwiftUI2 backend registered for this platform")
        }
        runner(windows)
    }
}
