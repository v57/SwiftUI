import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Toolbars. `.toolbar { ... }` splits its content into items (ToolbarItem / ToolbarItemGroup /
// plain views) that flow up as a preference. Navigation containers and the root collect them into
// the window's toolbar: hosts show plain buttons as native toolbar items (`ToolbarButton`) and
// embed anything else as a view rendered with the environment captured at the `.toolbar` site.

public enum ToolbarItemPlacement: Hashable, Sendable {
    case automatic, principal, navigation, primaryAction, secondaryAction, status, confirmationAction, cancellationAction, destructiveAction, keyboard, bottomBar, topBarLeading, topBarTrailing
}

public struct ToolbarPlacement: Hashable, Sendable {
    let id: Int
    public static let automatic = ToolbarPlacement(id: 0)
    public static let windowToolbar = ToolbarPlacement(id: 1)
    public static let navigationBar = ToolbarPlacement(id: 2)
}

/// A native toolbar button description (title and/or SF Symbol, action).
public struct ToolbarButton {
    public var title: String?
    public var systemImage: String?
    public var help: String?
    public var isEnabled = true
    public var isDestructive = false
    public var action: @MainActor () -> Void
}

/// One toolbar item.
public struct ToolbarEntry {
    /// Stable identity (the `.toolbar` site and the item's index in it).
    public let id: String
    public let placement: ToolbarItemPlacement
    public let content: AnyView
    /// Environment at the `.toolbar` site (hosted item views render with it).
    public let environment: EnvironmentValues
    /// Native representation for plain buttons; nil for other content.
    public let button: ToolbarButton?
    /// Item of a split view's sidebar column.
    public var isSidebarItem = false
    /// The window's search field (`searchable`); `content` renders it.
    public var search: ToolbarSearchField?
    /// Marks a sidebar-placed search field as hosted by a list (never reaches the window).
    var hostedSearch: ObjectIdentifier?
}

/// A `searchable` field shown in the window toolbar.
public struct ToolbarSearchField {
    public var prompt: String
    /// The current text (so the toolbar refreshes when it changes).
    public var text: String
}

extension ToolbarEntry: Equatable {
    public static func == (lhs: ToolbarEntry, rhs: ToolbarEntry) -> Bool {
        lhs.id == rhs.id && lhs.placement == rhs.placement && lhs.isSidebarItem == rhs.isSidebarItem
            && GraphComparison.isIdentical(lhs.content, rhs.content)
            && lhs.button?.title == rhs.button?.title && lhs.button?.systemImage == rhs.button?.systemImage
            && lhs.button?.isEnabled == rhs.button?.isEnabled && lhs.button?.help == rhs.button?.help
            && (lhs.button == nil) == (rhs.button == nil)
            && lhs.search?.text == rhs.search?.text && lhs.search?.prompt == rhs.search?.prompt
            && lhs.hostedSearch == rhs.hostedSearch
    }
}

public struct ToolbarItemsKey: PreferenceKey {
    public static var defaultValue: [ToolbarEntry] { [] }
    public static func reduce(value: inout [ToolbarEntry], nextValue: () -> [ToolbarEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// Window chrome requested by navigation containers.
public struct NavigationChrome: Equatable {
    /// A split view with a collapsible sidebar is present.
    public var hasSidebar = false
    /// Current sidebar column width (toolbar items after the sidebar line up with the detail).
    public var sidebarWidth: CGFloat = 0
    public var isSidebarVisible = true
    /// Toggles the sidebar (the toolbar's sidebar button).
    public var toggleSidebar: (@MainActor () -> Void)?
    /// Navigation containers use the unified window toolbar even without items.
    public var wantsToolbar = false
    /// `toolbar(removing: .sidebarToggle)`.
    public var removesSidebarToggle = false

    public init() {}

    public static func == (lhs: NavigationChrome, rhs: NavigationChrome) -> Bool {
        lhs.hasSidebar == rhs.hasSidebar && lhs.sidebarWidth == rhs.sidebarWidth && lhs.isSidebarVisible == rhs.isSidebarVisible
            && lhs.wantsToolbar == rhs.wantsToolbar && (lhs.toggleSidebar == nil) == (rhs.toggleSidebar == nil)
            && lhs.removesSidebarToggle == rhs.removesSidebarToggle
    }
}

public struct NavigationChromeKey: PreferenceKey {
    public static var defaultValue: NavigationChrome { NavigationChrome() }
    public static func reduce(value: inout NavigationChrome, nextValue: () -> NavigationChrome) {
        let next = nextValue()
        if next.hasSidebar {
            value.hasSidebar = true
            value.sidebarWidth = next.sidebarWidth
            value.isSidebarVisible = next.isSidebarVisible
            value.toggleSidebar = next.toggleSidebar
        }
        value.wantsToolbar = value.wantsToolbar || next.wantsToolbar
        value.removesSidebarToggle = value.removesSidebarToggle || next.removesSidebarToggle
    }
}

/// The window toolbar the root reports to its host.
public struct WindowToolbar: Equatable {
    public var items: [ToolbarEntry] = []
    public var chrome = NavigationChrome()
    public var isEmpty: Bool { items.isEmpty && !chrome.wantsToolbar && !chrome.hasSidebar }
    public init(items: [ToolbarEntry] = [], chrome: NavigationChrome = NavigationChrome()) {
        self.items = items
        self.chrome = chrome
    }
}

// MARK: - Items

/// Mirrors `SwiftUI.ToolbarContent`: toolbar items built with `@ToolbarContentBuilder`.
@MainActor @preconcurrency
public protocol ToolbarContent {
    associatedtype Body: ToolbarContent
    @ToolbarContentBuilder var body: Body { get }
    func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)])
}

extension ToolbarContent {
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {
        body._toolbarItems(into: &items)
    }
}

/// Customizable toolbar content (`.toolbar(id:)`) is treated like plain toolbar content.
public typealias CustomizableToolbarContent = ToolbarContent

extension Never: ToolbarContent {
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {}
}

public struct ToolbarItem<ID, Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == () {
        self.placement = placement
        self.content = content()
    }
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == String {
        self.placement = placement
        self.content = content()
    }
    public var body: Never { fatalError("ToolbarItem has no body") }

    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {
        // A missing (nil / empty) item is not shown at all.
        var inner: [(ToolbarItemPlacement, any View)] = []
        _collectToolbarItems(content, placement: placement, into: &inner)
        if !inner.isEmpty { items.append((placement, content)) }
    }
}

public struct ToolbarItemGroup<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
    public var body: Never { fatalError("ToolbarItemGroup has no body") }

    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {
        _collectToolbarItems(content, placement: placement, into: &items)
    }
}

/// Fixed or flexible space between toolbar items (macOS 26 `ToolbarSpacer`).
public struct ToolbarSpacer: ToolbarContent {
    public enum Sizing: Sendable { case fixed, flexible }
    public init(_ sizing: Sizing = .fixed, placement: ToolbarItemPlacement = .automatic) {}
    public var body: Never { fatalError("ToolbarSpacer has no body") }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {}
}

public struct _TupleToolbarContent: ToolbarContent {
    let parts: [@MainActor (inout [(ToolbarItemPlacement, any View)]) -> Void]
    public var body: Never { fatalError() }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) { for part in parts { part(&items) } }
}

public struct _EmptyToolbarContent: ToolbarContent {
    public var body: Never { fatalError() }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {}
}

extension Optional: ToolbarContent where Wrapped: ToolbarContent {
    public var body: Never { fatalError() }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) { self?._toolbarItems(into: &items) }
}

extension _ConditionalContent: ToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    public var body: Never { fatalError() }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) {
        switch storage {
        case .trueContent(let content): content._toolbarItems(into: &items)
        case .falseContent(let content): content._toolbarItems(into: &items)
        }
    }
}

extension Group: ToolbarContent where Content: ToolbarContent {
    public var body: Never { fatalError() }
    public init(@ToolbarContentBuilder content: () -> Content) { self.content = content() }
    public func _toolbarItems(into items: inout [(ToolbarItemPlacement, any View)]) { content._toolbarItems(into: &items) }
}

@resultBuilder @MainActor
public enum ToolbarContentBuilder {
    public static func buildExpression<C: ToolbarContent>(_ content: C) -> C { content }
    public static func buildBlock() -> _EmptyToolbarContent { _EmptyToolbarContent() }
    public static func buildBlock<C: ToolbarContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: ToolbarContent>(_ content: repeat each C) -> _TupleToolbarContent {
        var parts: [@MainActor (inout [(ToolbarItemPlacement, any View)]) -> Void] = []
        repeat parts.append({ items in (each content)._toolbarItems(into: &items) })
        return _TupleToolbarContent(parts: parts)
    }
    public static func buildOptional<C: ToolbarContent>(_ content: C?) -> C? { content }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }
    public static func buildLimitedAvailability<C: ToolbarContent>(_ content: C) -> C { content }
}

/// Splits view-built toolbar content into items.
@MainActor
protocol _ToolbarItemsProvider {
    func _toolbarItems(placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)])
}

@MainActor
func _collectToolbarItems(_ view: any View, placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)]) {
    if let provider = view as? _ToolbarItemsProvider {
        provider._toolbarItems(placement: placement, into: &items)
    } else if !(view is EmptyView) {
        items.append((placement, view))
    }
}

extension TupleView: _ToolbarItemsProvider {
    func _toolbarItems(placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)]) {
        for child in Mirror(reflecting: value).children {
            if let view = child.value as? any View { _collectToolbarItems(view, placement: placement, into: &items) }
        }
    }
}

extension Optional: _ToolbarItemsProvider where Wrapped: View {
    func _toolbarItems(placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)]) {
        if let self { _collectToolbarItems(self, placement: placement, into: &items) }
    }
}

extension _ConditionalContent: _ToolbarItemsProvider where TrueContent: View, FalseContent: View {
    func _toolbarItems(placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)]) {
        switch storage {
        case .trueContent(let view): _collectToolbarItems(view, placement: placement, into: &items)
        case .falseContent(let view): _collectToolbarItems(view, placement: placement, into: &items)
        }
    }
}

extension Group: _ToolbarItemsProvider where Content: View {
    func _toolbarItems(placement: ToolbarItemPlacement, into items: inout [(ToolbarItemPlacement, any View)]) {
        _collectToolbarItems(content, placement: placement, into: &items)
    }
}

// MARK: - Native buttons

@MainActor
protocol _ToolbarButtonConvertible {
    func _toolbarButton(environment: EnvironmentValues) -> ToolbarButton?
}

@MainActor
func _toolbarButton(for view: any View, environment: EnvironmentValues) -> ToolbarButton? {
    (view as? _ToolbarButtonConvertible)?._toolbarButton(environment: environment)
}

extension Button: _ToolbarButtonConvertible {
    func _toolbarButton(environment: EnvironmentValues) -> ToolbarButton? {
        var title: String?
        var image: String?
        if let text = label as? Text {
            title = text.plainString
        } else if let icon = label as? Image, case .system(let name) = icon.source {
            image = name
        } else if let both = label as? SwiftUI2Core.Label<Text, Image>, case .system(let name) = both.icon.source {
            title = both.title.plainString
            image = name
        } else {
            return nil
        }
        return ToolbarButton(title: title, systemImage: image, isEnabled: environment.isEnabled, isDestructive: role == .destructive, action: action)
    }
}

extension ModifiedContent: _ToolbarButtonConvertible where Content: View, Modifier: ViewModifier {
    func _toolbarButton(environment: EnvironmentValues) -> ToolbarButton? {
        var environment = environment
        if let writer = modifier as? _EnvironmentApplying { writer._apply(to: &environment) }
        guard var button = SwiftUI2Core._toolbarButton(for: content, environment: environment) else { return nil }
        if let help = modifier as? _HelpModifier, button.help == nil { button.help = help.text }
        return button
    }
}

extension Optional: _ToolbarButtonConvertible where Wrapped: View {
    func _toolbarButton(environment: EnvironmentValues) -> ToolbarButton? {
        self.flatMap { SwiftUI2Core._toolbarButton(for: $0, environment: environment) }
    }
}

extension _ConditionalContent: _ToolbarButtonConvertible where TrueContent: View, FalseContent: View {
    func _toolbarButton(environment: EnvironmentValues) -> ToolbarButton? {
        switch storage {
        case .trueContent(let view): SwiftUI2Core._toolbarButton(for: view, environment: environment)
        case .falseContent(let view): SwiftUI2Core._toolbarButton(for: view, environment: environment)
        }
    }
}

/// Environment modifiers that can be applied to plain values (toolbar button introspection).
@MainActor
protocol _EnvironmentApplying {
    func _apply(to environment: inout EnvironmentValues)
}

extension _EnvironmentKeyWritingModifier: _EnvironmentApplying {
    func _apply(to environment: inout EnvironmentValues) { environment[keyPath: keyPath] = value }
}

// MARK: - .toolbar

struct _ToolbarModifier: ViewModifier {
    let collect: @MainActor (inout [(ToolbarItemPlacement, any View)]) -> Void
    let site: Int
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        var collected: [(ToolbarItemPlacement, any View)] = []
        collect(&collected)
        let entries = collected.enumerated().map { index, item in
            ToolbarEntry(
                id: "\(site).\(index)", placement: item.0, content: AnyView(erasing: item.1), environment: environment,
                button: _toolbarButton(for: item.1, environment: environment)
            )
        }
        // Items of this `.toolbar` come before those of `.toolbar`s inside the content.
        return content.transformPreference(ToolbarItemsKey.self) { items in items = entries + items }
    }
}

@MainActor private var toolbarSiteCounter = 0

extension View {
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        toolbarSiteCounter += 1
        let items = content()
        return modifier(_ToolbarModifier(collect: { _collectToolbarItems(items, placement: .automatic, into: &$0) }, site: toolbarSiteCounter))
    }

    public func toolbar<Content: ToolbarContent>(@ToolbarContentBuilder content: () -> Content) -> some View {
        toolbarSiteCounter += 1
        let items = content()
        return modifier(_ToolbarModifier(collect: { items._toolbarItems(into: &$0) }, site: toolbarSiteCounter))
    }

    public func toolbar<Content: ToolbarContent>(id: String, @ToolbarContentBuilder content: () -> Content) -> some View {
        toolbar(content: content)
    }

    public func toolbarRole(_ role: ToolbarRole) -> some View { self }
    public func toolbarTitleDisplayMode(_ mode: ToolbarTitleDisplayMode) -> some View { self }
}

public enum ToolbarRole: Sendable { case automatic, navigationStack, browser, editor }
public enum ToolbarTitleDisplayMode: Sendable { case automatic, large, inline, inlineLarge }

// MARK: - help

/// `.help(_:)` — a tooltip on AppKit.
struct _HelpModifier: PlatformEffectModifier {
    let text: String
    static var pathComponent: String { "help" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }
    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.toolTip = AnyAttribute.withoutDependencies { modifier.value.text }
        return actions
    }
}

// MARK: - @ContentBuilder

/// The unified content builder (macOS 27 SDK): builds views or toolbar content, chosen by the
/// declared result type.
@resultBuilder @MainActor
public enum ContentBuilder {
    // Toolbar content.
    public static func buildExpression<C: ToolbarContent>(_ content: C) -> C { content }
    public static func buildBlock<C: ToolbarContent>(_ content: C) -> C { content }
    public static func buildBlock<each C: ToolbarContent>(_ content: repeat each C) -> _TupleToolbarContent {
        ToolbarContentBuilder.buildBlock(repeat each content)
    }
    public static func buildOptional<C: ToolbarContent>(_ content: C?) -> C? { content }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: ToolbarContent, F: ToolbarContent>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }

    // Views.
    public static func buildExpression<V: View>(_ content: V) -> V { content }
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<V: View>(_ content: V) -> V { content }
    public static func buildBlock<each V: View>(_ content: repeat each V) -> TupleView<(repeat each V)> { TupleView((repeat each content)) }
    public static func buildOptional<V: View>(_ content: V?) -> V? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }
}
