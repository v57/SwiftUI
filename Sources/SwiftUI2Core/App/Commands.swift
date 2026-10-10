import Foundation

// Menu bar commands. `Commands` values (with bodies, like views) produce `CommandEntry`s: custom
// menus and groups inserted relative to the standard menus' placements. Backends evaluate them
// whenever a menu is about to show, so state read in a body stays current.

@MainActor @preconcurrency
public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Body { get }
    func _commandEntries(into entries: inout [CommandEntry])
}

extension Commands {
    public func _commandEntries(into entries: inout [CommandEntry]) {
        // Commands structs may read @Environment / @Observable state; outside a view graph they
        // see the app environment.
        EnvironmentValues.withAmbient(AppRuntime.environment) { body._commandEntries(into: &entries) }
    }
}

extension Never: Commands {
    public func _commandEntries(into entries: inout [CommandEntry]) {}
}

public enum CommandGroupPlacement: Hashable, Sendable {
    case appInfo, appSettings, systemServices, appVisibility, appTermination, newItem, saveItem, importExport, printItem, undoRedo, pasteboard, textEditing, textFormatting, toolbar, sidebar, windowSize, windowList, singleWindowList, windowArrangement, help
}

public enum CommandEntry {
    public enum Position: Sendable { case replacing, before, after }
    /// A new top-level menu (inserted before Window/Help).
    case menu(title: String, items: @MainActor () -> [MenuItem])
    case group(placement: CommandGroupPlacement, position: Position, items: @MainActor () -> [MenuItem])
    /// A standard command set (`TextEditingCommands()`, `SidebarCommands()`, ...).
    case standard(String)
}

public struct CommandGroup<Content: View>: Commands {
    let placement: CommandGroupPlacement
    let position: CommandEntry.Position
    let content: () -> Content

    public init(replacing placement: CommandGroupPlacement, @ViewBuilder addition: @escaping () -> Content) {
        self.placement = placement
        self.position = .replacing
        self.content = addition
    }
    public init(after placement: CommandGroupPlacement, @ViewBuilder addition: @escaping () -> Content) {
        self.placement = placement
        self.position = .after
        self.content = addition
    }
    public init(before placement: CommandGroupPlacement, @ViewBuilder addition: @escaping () -> Content) {
        self.placement = placement
        self.position = .before
        self.content = addition
    }

    public var body: Never { fatalError("CommandGroup has no body") }

    public func _commandEntries(into entries: inout [CommandEntry]) {
        let content = self.content
        entries.append(.group(placement: placement, position: position, items: {
            EnvironmentValues.withAmbient(AppRuntime.environment) { MenuItems.items(content(), environment: AppRuntime.environment) }
        }))
    }
}

public struct CommandMenu<Content: View>: Commands {
    let name: String
    let content: () -> Content

    @_disfavoredOverload public init<S: StringProtocol>(_ name: S, @ViewBuilder content: @escaping () -> Content) {
        self.name = String(name)
        self.content = content
    }
    public init(_ nameKey: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.name = nameKey.key
        self.content = content
    }
    public init(_ name: Text, @ViewBuilder content: @escaping () -> Content) {
        self.name = name.plainString
        self.content = content
    }

    public var body: Never { fatalError("CommandMenu has no body") }

    public func _commandEntries(into entries: inout [CommandEntry]) {
        let content = self.content
        entries.append(.menu(title: name, items: {
            EnvironmentValues.withAmbient(AppRuntime.environment) { MenuItems.items(content(), environment: AppRuntime.environment) }
        }))
    }
}

/// Standard command sets.
public struct TextEditingCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) { entries.append(.standard("textEditing")) } }
public struct TextFormattingCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) { entries.append(.standard("textFormatting")) } }
public struct SidebarCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) { entries.append(.standard("sidebar")) } }
public struct ToolbarCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) { entries.append(.standard("toolbar")) } }
public struct InspectorCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) { entries.append(.standard("inspector")) } }
public struct ImportFromDevicesCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) {} }
public struct EmptyCommands: Commands { public init() {}; public var body: Never { fatalError() }; public func _commandEntries(into entries: inout [CommandEntry]) {} }

public struct _TupleCommands: Commands {
    let parts: [@MainActor (inout [CommandEntry]) -> Void]
    public var body: Never { fatalError() }
    public func _commandEntries(into entries: inout [CommandEntry]) { for part in parts { part(&entries) } }
}

extension Optional: Commands where Wrapped: Commands {
    public var body: Never { fatalError() }
    public func _commandEntries(into entries: inout [CommandEntry]) { self?._commandEntries(into: &entries) }
}

extension _ConditionalContent: Commands where TrueContent: Commands, FalseContent: Commands {
    public var body: Never { fatalError() }
    public func _commandEntries(into entries: inout [CommandEntry]) {
        switch storage {
        case .trueContent(let content): content._commandEntries(into: &entries)
        case .falseContent(let content): content._commandEntries(into: &entries)
        }
    }
}

extension Group: Commands where Content: Commands {
    public var body: Never { fatalError() }
    public init(@CommandsBuilder content: () -> Content) { self.content = content() }
    public func _commandEntries(into entries: inout [CommandEntry]) { content._commandEntries(into: &entries) }
}

@resultBuilder @MainActor
public enum CommandsBuilder {
    public static func buildExpression<C: Commands>(_ content: C) -> C { content }
    public static func buildBlock() -> EmptyCommands { EmptyCommands() }
    public static func buildBlock<C: Commands>(_ content: C) -> C { content }
    public static func buildBlock<each C: Commands>(_ content: repeat each C) -> _TupleCommands {
        var parts: [@MainActor (inout [CommandEntry]) -> Void] = []
        repeat parts.append({ entries in (each content)._commandEntries(into: &entries) })
        return _TupleCommands(parts: parts)
    }
    public static func buildOptional<C: Commands>(_ content: C?) -> C? { content }
    public static func buildEither<T: Commands, F: Commands>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: Commands, F: Commands>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }
    public static func buildLimitedAvailability<C: Commands>(_ content: C) -> C { content }
}

// MARK: - Window actions

/// Mirrors `SwiftUI.OpenWindowAction`.
public struct OpenWindowAction: Sendable {
    public init() {}
    @MainActor public func callAsFunction(id: String) { AppRuntime.openWindow?(id, nil) }
    @MainActor public func callAsFunction<D: Codable & Hashable>(id: String, value: D) { AppRuntime.openWindow?(id, AnyHashable(value)) }
    @MainActor public func callAsFunction<D: Codable & Hashable>(value: D) { AppRuntime.openWindow?(nil, AnyHashable(value)) }
}

/// Mirrors `SwiftUI.DismissWindowAction`.
public struct DismissWindowAction: Sendable {
    let current: (@MainActor @Sendable () -> Void)?
    public init() { current = nil }
    /// Dismisses the window the view is in (backends install it per window).
    public init(_current current: @escaping @MainActor @Sendable () -> Void) { self.current = current }
    @MainActor public func callAsFunction() { current?() }
    @MainActor public func callAsFunction(id: String) { AppRuntime.dismissWindow?(id, nil) }
    @MainActor public func callAsFunction<D: Codable & Hashable>(id: String, value: D) { AppRuntime.dismissWindow?(id, AnyHashable(value)) }
    @MainActor public func callAsFunction<D: Codable & Hashable>(value: D) { AppRuntime.dismissWindow?(nil, AnyHashable(value)) }
}

struct OpenWindowKey: EnvironmentKey { static let defaultValue = OpenWindowAction() }
struct DismissWindowKey: EnvironmentKey { static let defaultValue = DismissWindowAction() }

extension EnvironmentValues {
    public var openWindow: OpenWindowAction {
        get { self[OpenWindowKey.self] }
        set { self[OpenWindowKey.self] = newValue }
    }
    public var dismissWindow: DismissWindowAction {
        get { self[DismissWindowKey.self] }
        set { self[DismissWindowKey.self] = newValue }
    }
}
