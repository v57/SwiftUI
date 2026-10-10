import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import Observation

// MARK: - Scene modifiers

/// A scene whose window descriptions are adjusted (`windowStyle`, `defaultPosition`, ...).
public struct _ModifiedScene<Base: Scene>: Scene {
    let base: Base
    let transform: @MainActor (inout WindowDescription) -> Void
    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        var collected: [WindowDescription] = []
        base._collectWindows(into: &collected)
        for var window in collected {
            transform(&window)
            windows.append(window)
        }
    }

    public func _collectCommands(into commands: inout [any Commands]) { base._collectCommands(into: &commands) }
}

public enum WindowToolbarStyleKind: Hashable, Sendable { case automatic, unified, unifiedCompact, expanded }

public protocol WindowStyle { var _kind: WindowKind { get } }
public struct DefaultWindowStyle: WindowStyle { public init() {}; public var _kind: WindowKind { .standard } }
public struct TitleBarWindowStyle: WindowStyle { public init() {}; public var _kind: WindowKind { .standard } }
public struct HiddenTitleBarWindowStyle: WindowStyle { public init() {}; public var _kind: WindowKind { .hiddenTitleBar } }
public struct PlainWindowStyle: WindowStyle { public init() {}; public var _kind: WindowKind { .plain } }
extension WindowStyle where Self == DefaultWindowStyle { public static var automatic: DefaultWindowStyle { .init() } }
extension WindowStyle where Self == TitleBarWindowStyle { public static var titleBar: TitleBarWindowStyle { .init() } }
extension WindowStyle where Self == HiddenTitleBarWindowStyle { public static var hiddenTitleBar: HiddenTitleBarWindowStyle { .init() } }
extension WindowStyle where Self == PlainWindowStyle { public static var plain: PlainWindowStyle { .init() } }

public protocol WindowToolbarStyle { var _kind: WindowToolbarStyleKind { get } }
public struct DefaultWindowToolbarStyle: WindowToolbarStyle { public init() {}; public var _kind: WindowToolbarStyleKind { .automatic } }
public struct UnifiedWindowToolbarStyle: WindowToolbarStyle {
    public init() {}
    public init(showsTitle: Bool) {}
    public var _kind: WindowToolbarStyleKind { .unified }
}
public struct UnifiedCompactWindowToolbarStyle: WindowToolbarStyle {
    public init() {}
    public init(showsTitle: Bool) {}
    public var _kind: WindowToolbarStyleKind { .unifiedCompact }
}
public struct ExpandedWindowToolbarStyle: WindowToolbarStyle { public init() {}; public var _kind: WindowToolbarStyleKind { .expanded } }
extension WindowToolbarStyle where Self == DefaultWindowToolbarStyle { public static var automatic: DefaultWindowToolbarStyle { .init() } }
extension WindowToolbarStyle where Self == UnifiedWindowToolbarStyle {
    public static var unified: UnifiedWindowToolbarStyle { .init() }
    public static func unified(showsTitle: Bool) -> UnifiedWindowToolbarStyle { .init(showsTitle: showsTitle) }
}
extension WindowToolbarStyle where Self == UnifiedCompactWindowToolbarStyle {
    public static var unifiedCompact: UnifiedCompactWindowToolbarStyle { .init() }
    public static func unifiedCompact(showsTitle: Bool) -> UnifiedCompactWindowToolbarStyle { .init(showsTitle: showsTitle) }
}
extension WindowToolbarStyle where Self == ExpandedWindowToolbarStyle { public static var expanded: ExpandedWindowToolbarStyle { .init() } }

public enum SceneLaunchBehavior: Hashable, Sendable { case automatic, presented, suppressed }
public enum SceneRestorationBehavior: Hashable, Sendable { case automatic, disabled }
public enum WindowLevel: Hashable, Sendable { case automatic, normal, floating, desktop }

extension Scene {
    public func windowStyle<S: WindowStyle>(_ style: S) -> some Scene {
        _ModifiedScene(base: self) { $0.kind = $0.kind == .utility ? .utility : style._kind }
    }
    public func windowResizability(_ resizability: WindowResizability) -> some Scene {
        _ModifiedScene(base: self) { $0.resizability = resizability }
    }
    public func defaultPosition(_ position: UnitPoint) -> some Scene {
        _ModifiedScene(base: self) { $0.defaultPosition = position }
    }
    public func windowToolbarStyle<S: WindowToolbarStyle>(_ style: S) -> some Scene {
        _ModifiedScene(base: self) { $0.toolbarStyle = style._kind }
    }
    public func defaultLaunchBehavior(_ behavior: SceneLaunchBehavior) -> some Scene {
        _ModifiedScene(base: self) { $0.launchBehavior = behavior }
    }
    /// Window frames are restored between launches unless disabled.
    public func restorationBehavior(_ behavior: SceneRestorationBehavior) -> some Scene { self }
    public func windowLevel(_ level: WindowLevel) -> some Scene {
        _ModifiedScene(base: self) { $0.level = level }
    }
    public func defaultSize(_ size: CGSize) -> some Scene {
        _ModifiedScene(base: self) { window in
            window = window.withDefaultSize(size)
        }
    }
    public func defaultSize(width: CGFloat, height: CGFloat) -> some Scene { defaultSize(CGSize(width: width, height: height)) }
    /// Keyboard shortcut of the window's "Show" command (Window menu).
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some Scene { self }
}

extension WindowDescription {
    func withDefaultSize(_ size: CGSize) -> WindowDescription {
        var copy = WindowDescription(title: title, defaultSize: size, makeGraph: makeGraphForValue)
        copy.role = role
        copy.id = id
        copy.valueType = valueType
        copy.isSingle = isSingle
        copy.kind = kind
        copy.resizability = resizability
        copy.defaultPosition = defaultPosition
        copy.toolbarStyle = toolbarStyle
        copy.launchBehavior = launchBehavior
        copy.level = level
        copy.menuBarExtra = menuBarExtra
        copy.document = document
        return copy
    }
}

// MARK: - UtilityWindow

/// A floating utility panel, shown and hidden from the View menu (macOS 15).
public struct UtilityWindow<Content: View>: Scene {
    let title: String
    let id: String
    let content: () -> Content

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
        var description = WindowDescription(title: title, defaultSize: nil) { backend in
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        }
        description.id = id
        description.isSingle = true
        description.kind = .utility
        description.level = .floating
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}
}

// MARK: - MenuBarExtra

/// A status item: a menu, or a window-style popover (`menuBarExtraStyle(.window)`).
@MainActor
public struct MenuBarExtraDescription {
    public let title: String
    public let systemImage: String?
    public var isWindowStyle = false
    public let isInserted: Binding<Bool>?
    /// The menu's items (menu style), evaluated when the menu opens.
    public let menuItems: @MainActor () -> [MenuItem]
}

public struct MenuBarExtra<Label: View, Content: View>: Scene {
    let title: String
    let systemImage: String?
    let isInserted: Binding<Bool>?
    let content: () -> Content

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, isInserted: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) where Label == SwiftUI2Core.Label<Text, Image> {
        self.title = String(title)
        self.systemImage = systemImage
        self.isInserted = isInserted
        self.content = content
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isInserted: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) where Label == Text {
        self.title = String(title)
        self.systemImage = nil
        self.isInserted = isInserted
        self.content = content
    }

    public init(isInserted: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        let (title, symbol) = MenuItems.title(of: label())
        self.title = title
        self.systemImage = symbol
        self.isInserted = isInserted
        self.content = content
    }

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        var description = WindowDescription(title: title, defaultSize: nil) { backend in
            ViewGraph(rootView: _WindowContent(content: content), backend: backend)
        }
        description.role = .main
        description.kind = .plain
        description.launchBehavior = .suppressed
        description.menuBarExtra = MenuBarExtraDescription(
            title: title, systemImage: systemImage, isInserted: isInserted,
            menuItems: { EnvironmentValues.withAmbient(AppRuntime.environment) { MenuItems.items(content(), environment: AppRuntime.environment) } }
        )
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}
}

public protocol MenuBarExtraStyle { var _isWindow: Bool { get } }
public struct PullDownMenuBarExtraStyle: MenuBarExtraStyle { public init() {}; public var _isWindow: Bool { false } }
public struct WindowMenuBarExtraStyle: MenuBarExtraStyle { public init() {}; public var _isWindow: Bool { true } }
public typealias AutomaticMenuBarExtraStyle = PullDownMenuBarExtraStyle
extension MenuBarExtraStyle where Self == PullDownMenuBarExtraStyle {
    public static var automatic: PullDownMenuBarExtraStyle { .init() }
    public static var menu: PullDownMenuBarExtraStyle { .init() }
}
extension MenuBarExtraStyle where Self == WindowMenuBarExtraStyle { public static var window: WindowMenuBarExtraStyle { .init() } }

extension Scene {
    public func menuBarExtraStyle<S: MenuBarExtraStyle>(_ style: S) -> some Scene {
        _ModifiedScene(base: self) { $0.menuBarExtra?.isWindowStyle = style._isWindow }
    }
}

// MARK: - Documents

/// A value-type document read from and written to files (`DocumentGroup(newDocument:)`).
@preconcurrency
public protocol FileDocument {
    #if canImport(UniformTypeIdentifiers)
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    #endif
    init(configuration: ReadConfiguration) throws
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
    typealias ReadConfiguration = FileDocumentReadConfiguration
    typealias WriteConfiguration = FileDocumentWriteConfiguration
}

#if canImport(UniformTypeIdentifiers)
extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}
#endif

public struct FileDocumentReadConfiguration {
    #if canImport(UniformTypeIdentifiers)
    public let contentType: UTType
    #endif
    public let file: FileWrapper
}

public struct FileDocumentWriteConfiguration {
    #if canImport(UniformTypeIdentifiers)
    public let contentType: UTType
    #endif
    public let existingFile: FileWrapper?
}

/// A reference-type document (an `ObservableObject`) that saves snapshots.
@preconcurrency
public protocol ReferenceFileDocument: ObservableObject {
    associatedtype Snapshot
    #if canImport(UniformTypeIdentifiers)
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    func snapshot(contentType: UTType) throws -> Snapshot
    #endif
    init(configuration: ReadConfiguration) throws
    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper
    typealias ReadConfiguration = FileDocumentReadConfiguration
    typealias WriteConfiguration = FileDocumentWriteConfiguration
}

#if canImport(UniformTypeIdentifiers)
extension ReferenceFileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}
#endif

/// What a document window's content gets: the document binding and its file.
public struct FileDocumentConfiguration<Document: FileDocument> {
    @Binding public var document: Document
    public var fileURL: URL?
    public var isEditable: Bool
}

@MainActor
public struct ReferenceFileDocumentConfiguration<Document: ReferenceFileDocument> {
    @ObservedObject public var document: Document
    public var fileURL: URL?
    public var isEditable: Bool

    init(document: Document, fileURL: URL?, isEditable: Bool) {
        self._document = ObservedObject(wrappedValue: document)
        self.fileURL = fileURL
        self.isEditable = isEditable
    }
}

/// An open document (backends save and title windows through it).
@MainActor
public protocol _DocumentHandle: AnyObject {
    var fileURL: URL? { get set }
    var isEdited: Bool { get set }
    var writableTypeIdentifiers: [String] { get }
    func write(to url: URL, typeIdentifier: String) throws
}

/// Document scene description for backends.
@MainActor
public struct DocumentSceneDescription {
    public let readableTypeIdentifiers: [String]
    public let isViewer: Bool
    public let makeNew: (@MainActor () -> any _DocumentHandle)?
    public let open: @MainActor (URL) throws -> any _DocumentHandle
}

/// Wraps a handle so it can be a window's presented value.
public struct _DocumentWindowValue: Hashable, @unchecked Sendable {
    public let handle: any _DocumentHandle
    public init(handle: any _DocumentHandle) { self.handle = handle }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.handle === rhs.handle }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(handle)) }
}

#if canImport(UniformTypeIdentifiers)
@Observable
@MainActor
final class _FileDocumentBox<Document: FileDocument>: _DocumentHandle {
    var document: Document {
        didSet { isEdited = true }
    }
    var fileURL: URL?
    var isEdited = false
    var writableTypeIdentifiers: [String] { Document.writableContentTypes.map(\.identifier) }

    init(document: Document, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
    }

    func write(to url: URL, typeIdentifier: String) throws {
        let type = UTType(typeIdentifier) ?? Document.writableContentTypes.first ?? .data
        let wrapper = try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: type, existingFile: nil))
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        fileURL = url
        isEdited = false
    }
}

@MainActor
final class _ReferenceDocumentBox<Document: ReferenceFileDocument>: _DocumentHandle {
    let document: Document
    var fileURL: URL?
    var isEdited = false
    var writableTypeIdentifiers: [String] { Document.writableContentTypes.map(\.identifier) }

    init(document: Document, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
    }

    func write(to url: URL, typeIdentifier: String) throws {
        let type = UTType(typeIdentifier) ?? Document.writableContentTypes.first ?? .data
        let snapshot = try document.snapshot(contentType: type)
        let wrapper = try document.fileWrapper(snapshot: snapshot, configuration: FileDocumentWriteConfiguration(contentType: type, existingFile: nil))
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        fileURL = url
        isEdited = false
    }
}

func _readConfiguration(url: URL, types: [UTType]) throws -> FileDocumentReadConfiguration {
    let wrapper = try FileWrapper(url: url, options: .immediate)
    #if canImport(Darwin)
    let fileType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? types.first ?? .data
    #else
    let fileType = UTType(filenameExtension: url.pathExtension) ?? types.first ?? .data
    #endif
    return FileDocumentReadConfiguration(contentType: fileType, file: wrapper)
}

/// Document-based app windows: File > New / Open / Save, one window per document.
public struct DocumentGroup<Document, Content: View>: Scene {
    let readable: [String]
    let isViewer: Bool
    let makeNew: (@MainActor () -> any _DocumentHandle)?
    let open: @MainActor (URL) throws -> any _DocumentHandle
    let content: @MainActor (any _DocumentHandle) -> Content

    public var body: Never { fatalError() }

    public func _collectWindows(into windows: inout [WindowDescription]) {
        let content = self.content
        var description = WindowDescription(title: "", defaultSize: nil) { backend, value in
            let handle = (value?.base as? _DocumentWindowValue)?.handle
            return ViewGraph(rootView: _WindowContent(content: { _DocumentWindowContent(handle: handle, content: content) }), backend: backend)
        }
        description.id = "SwiftUI2.DocumentGroup"
        description.valueType = _DocumentWindowValue.self
        description.document = DocumentSceneDescription(readableTypeIdentifiers: readable, isViewer: isViewer, makeNew: makeNew, open: open)
        windows.append(description)
    }

    public func _collectCommands(into commands: inout [any Commands]) {}
}

struct _DocumentWindowContent<Content: View>: View {
    let handle: (any _DocumentHandle)?
    let content: @MainActor (any _DocumentHandle) -> Content
    var body: some View {
        if let handle { content(handle) }
    }
}

extension DocumentGroup where Document: FileDocument {
    public init(newDocument: @autoclosure @escaping @MainActor () -> Document, @ViewBuilder editor: @escaping @MainActor (FileDocumentConfiguration<Document>) -> Content) {
        readable = Document.readableContentTypes.map(\.identifier)
        isViewer = false
        makeNew = { _FileDocumentBox(document: newDocument(), fileURL: nil) }
        open = { url in
            let document = try Document(configuration: _readConfiguration(url: url, types: Document.readableContentTypes))
            return _FileDocumentBox(document: document, fileURL: url)
        }
        content = { handle in
            let box = handle as! _FileDocumentBox<Document>
            return editor(FileDocumentConfiguration(document: Binding(get: { box.document }, set: { box.document = $0 }), fileURL: box.fileURL, isEditable: true))
        }
    }

    public init(viewing documentType: Document.Type, @ViewBuilder viewer: @escaping @MainActor (FileDocumentConfiguration<Document>) -> Content) {
        readable = Document.readableContentTypes.map(\.identifier)
        isViewer = true
        makeNew = nil
        open = { url in
            let document = try Document(configuration: _readConfiguration(url: url, types: Document.readableContentTypes))
            return _FileDocumentBox(document: document, fileURL: url)
        }
        content = { handle in
            let box = handle as! _FileDocumentBox<Document>
            return viewer(FileDocumentConfiguration(document: .constant(box.document), fileURL: box.fileURL, isEditable: false))
        }
    }
}

extension DocumentGroup where Document: ReferenceFileDocument {
    public init(newDocument: @escaping @MainActor () -> Document, @ViewBuilder editor: @escaping @MainActor (ReferenceFileDocumentConfiguration<Document>) -> Content) {
        readable = Document.readableContentTypes.map(\.identifier)
        isViewer = false
        makeNew = { _ReferenceDocumentBox(document: newDocument(), fileURL: nil) }
        open = { url in
            let document = try Document(configuration: _readConfiguration(url: url, types: Document.readableContentTypes))
            return _ReferenceDocumentBox(document: document, fileURL: url)
        }
        content = { handle in
            let box = handle as! _ReferenceDocumentBox<Document>
            return editor(ReferenceFileDocumentConfiguration(document: box.document, fileURL: box.fileURL, isEditable: true))
        }
    }

    public init(viewing documentType: Document.Type, @ViewBuilder viewer: @escaping @MainActor (ReferenceFileDocumentConfiguration<Document>) -> Content) {
        readable = Document.readableContentTypes.map(\.identifier)
        isViewer = true
        makeNew = nil
        open = { url in
            let document = try Document(configuration: _readConfiguration(url: url, types: Document.readableContentTypes))
            return _ReferenceDocumentBox(document: document, fileURL: url)
        }
        content = { handle in
            let box = handle as! _ReferenceDocumentBox<Document>
            return viewer(ReferenceFileDocumentConfiguration(document: box.document, fileURL: box.fileURL, isEditable: false))
        }
    }
}
#endif

// MARK: - Runtime actions

extension AppRuntime {
    /// Opens the Settings window (installed by the backend runner).
    public static var openSettings: (@MainActor () -> Void)?
    /// Creates a new untitled document window (DocumentGroup apps).
    public static var newDocument: (@MainActor () -> Void)?
    /// Whether a window with the id is open.
    public static var isWindowOpen: (@MainActor (String) -> Bool)?
}
