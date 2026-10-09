import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Titles & toolbars (preferences)

/// The window subtitle (`navigationSubtitle`).
public struct NavigationSubtitleKey: PreferenceKey {
    public static var defaultValue: String? { nil }
    public static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

public struct NavigationTitleKey: PreferenceKey {
    public static var defaultValue: Text? { nil }
    public static func reduce(value: inout Text?, nextValue: () -> Text?) {
        if let next = nextValue() { value = next }
    }
}

public struct ColumnWidthKey: PreferenceKey {
    public static var defaultValue: CGFloat? { nil }
    public static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

public enum NavigationBarItem { public enum TitleDisplayMode: Sendable { case automatic, inline, large } }

extension View {
    public func navigationTitle(_ title: Text) -> some View { preference(key: NavigationTitleKey.self, value: title) }
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { preference(key: NavigationTitleKey.self, value: Text(title)) }
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { preference(key: NavigationTitleKey.self, value: Text(titleKey)) }
    public func navigationSubtitle<S: StringProtocol>(_ subtitle: S) -> some View { preference(key: NavigationSubtitleKey.self, value: String(subtitle)) }
    public func navigationSubtitle(_ subtitle: Text) -> some View { preference(key: NavigationSubtitleKey.self, value: subtitle.plainString) }
    public func navigationSubtitle(_ subtitleKey: LocalizedStringKey) -> some View { preference(key: NavigationSubtitleKey.self, value: subtitleKey.key) }
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View { self }

    public func navigationSplitViewColumnWidth(_ width: CGFloat) -> some View {
        preference(key: ColumnWidthKey.self, value: width)
    }

    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        preference(key: ColumnWidthKey.self, value: ideal)
    }
}

// MARK: - NavigationPath / NavigationStack

public struct NavigationPath: Equatable {
    var elements: [AnyHashable] = []
    public init() {}
    public init<S: Sequence>(_ elements: S) where S.Element: Hashable { self.elements = elements.map { AnyHashable($0) } }
    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }
    public mutating func append<V: Hashable>(_ value: V) { elements.append(AnyHashable(value)) }
    public mutating func removeLast(_ k: Int = 1) { elements.removeLast(Swift.min(k, elements.count)) }
}

/// Destination builders registered by `.navigationDestination(for:)`, keyed by value type.
@MainActor
final class NavigationDestinations {
    var builders: [ObjectIdentifier: Attribute<(Any) -> AnyView>] = [:]
    var direct: [AnyHashable: AnyView] = [:]

    func view(for value: AnyHashable) -> AnyView? {
        if let direct = direct[value] { return direct }
        let base = value.base
        let key = ObjectIdentifier(type(of: base))
        return builders[key]?.value(base)
    }
}

@MainActor
struct NavigationContext {
    let push: @MainActor (AnyHashable) -> Void
    let pushView: @MainActor (AnyView) -> Void
    let destinations: NavigationDestinations
}

struct NavigationContextKey: EnvironmentKey { static let defaultValue: NavigationContext? = nil }

extension NavigationContext: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: NavigationContext, _ rhs: NavigationContext) -> Bool {
        MainActor.assumeIsolated { lhs.destinations === rhs.destinations }
    }
}

extension EnvironmentValues {
    var navigationContext: NavigationContext? {
        get { self[NavigationContextKey.self] }
        set { self[NavigationContextKey.self] = newValue }
    }
}

struct _DirectDestinationID: Hashable { let id: Int }

public struct NavigationStack<Root: View>: View {
    let root: Root
    let externalPath: Binding<[AnyHashable]>?
    @State private var internalPath: [AnyHashable] = []
    @State private var destinations = NavigationDestinations()
    @State private var directCounter = 0

    public init(@ViewBuilder root: () -> Root) {
        self.root = root()
        self.externalPath = nil
    }

    public init<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection>(path: Binding<Data>, @ViewBuilder root: () -> Root) where Data.Element: Hashable {
        self.root = root()
        self.externalPath = Binding(
            get: { path.wrappedValue.map { AnyHashable($0) } },
            set: { newValue in path.wrappedValue = Data(newValue.compactMap { $0.base as? Data.Element }) }
        )
    }

    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        self.root = root()
        self.externalPath = Binding(get: { path.wrappedValue.elements }, set: { path.wrappedValue.elements = $0 })
    }

    private var path: Binding<[AnyHashable]> { externalPath ?? $internalPath }

    public var body: some View {
        let path = self.path
        let depth = path.wrappedValue.count
        let destinations = self.destinations
        let context = NavigationContext(
            push: { path.wrappedValue.append($0) },
            pushView: { view in
                directCounter += 1
                let id = AnyHashable(_DirectDestinationID(id: directCounter))
                destinations.direct[id] = view
                path.wrappedValue.append(id)
            },
            destinations: destinations
        )
        // macOS: titles go to the window title and toolbar items (plus a back button) to the
        // window toolbar; only the visible level contributes.
        ZStack(alignment: .topLeading) {
            level(0, content: AnyView(root), depth: depth)
            ForEach(Array(path.wrappedValue.enumerated()), id: \.offset) { index, value in
                level(index + 1, content: destinations.view(for: value) ?? AnyView(Text("No destination for \(String(describing: value.base))")), depth: depth)
                    .environment(\.dismiss, DismissAction { if path.wrappedValue.count > index { path.wrappedValue.removeLast(path.wrappedValue.count - index) } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transformPreference(ToolbarItemsKey.self) { items in
            guard depth > 0 else { return }
            let back = ToolbarButton(systemImage: "chevron.backward", help: "Back", action: { path.wrappedValue.removeLast() })
            items.insert(ToolbarEntry(id: "navigation.back", placement: .navigation, content: AnyView(EmptyView()), environment: EnvironmentValues(), button: back), at: 0)
        }
        .transformPreference(NavigationChromeKey.self) { chrome in chrome.wantsToolbar = true }
        .environment(\.navigationContext, context)
    }

    private func level(_ index: Int, content: AnyView, depth: Int) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.controlBackground)
            .opacity(index == depth ? 1 : 0)
            .allowsHitTesting(index == depth)
            .transformPreference(NavigationTitleKey.self) { if index != depth { $0 = nil } }
            .transformPreference(ToolbarItemsKey.self) { if index != depth { $0 = [] } }
            .transition(.move(edge: .trailing))
    }
}

public struct NavigationLink<Label: View, Destination: View>: View {
    let label: Label
    let value: AnyHashable?
    let destination: Destination?
    @Environment(\.navigationContext) private var context

    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = destination()
        self.value = nil
    }

    public init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.destination = destination
        self.value = nil
    }

    public var body: some View {
        Button {
            if let value { context?.push(value) } else if let destination { context?.pushView(AnyView(destination)) }
        } label: {
            // macOS list rows show no disclosure chevron.
            HStack {
                label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension NavigationLink where Destination == Never {
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.value = value.map { AnyHashable($0) }
        self.destination = nil
    }
}

extension NavigationLink where Label == Text, Destination == Never {
    public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?) {
        self.init(value: value) { Text(title) }
    }
}

extension NavigationLink where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

public struct _NavigationDestinationModifier<D: Hashable, Destination: View>: ViewModifier {
    let destination: (D) -> Destination
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let environment = inputs.environment
        let builder = Attribute<(Any) -> AnyView>(inputs.subgraph, isEqual: GraphComparison.never) {
            let make = modifier.attribute.value.destination
            return { value in AnyView(make(value as! D)) }
        }
        if let context = AnyAttribute.withoutDependencies({ environment.value.navigationContext }) {
            context.destinations.builders[ObjectIdentifier(D.self)] = builder
        }
        return body(inputs)
    }
}

extension View {
    public func navigationDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        modifier(_NavigationDestinationModifier(destination: destination))
    }

    public func navigationDestination<V: View>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> V) -> some View {
        sheet(isPresented: isPresented) { [content = destination()] in content }
    }
}

// MARK: - NavigationSplitView

public enum NavigationSplitViewVisibility: Hashable, Sendable { case automatic, all, doubleColumn, detailOnly }

public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {
    let sidebar: Sidebar
    let content: Content?
    let detail: Detail
    let columnVisibility: Binding<NavigationSplitViewVisibility>?
    @State private var sidebarWidth: CGFloat = 144  // SwiftUI's default sidebar column width on macOS
    @State private var contentWidth: CGFloat = 260
    @State private var internalVisibility = NavigationSplitViewVisibility.automatic

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        self.columnVisibility = nil
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        self.columnVisibility = columnVisibility
    }

    private var visibility: Binding<NavigationSplitViewVisibility> { columnVisibility ?? $internalVisibility }

    public var body: some View {
        let visibility = self.visibility
        let showsSidebar = visibility.wrappedValue != .detailOnly
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar
                    .environment(\.isSidebarColumn, true)
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.sidebarBackground)
                    .onPreferenceChange(ColumnWidthKey.self) { if let width = $0 { sidebarWidth = width } }
                    // The sidebar's title is not the window's; its toolbar items sit over the sidebar.
                    .transformPreference(NavigationTitleKey.self) { $0 = nil }
                    .transformPreference(ToolbarItemsKey.self) { items in
                        for index in items.indices { items[index].isSidebarItem = true }
                    }
                    .transition(.move(edge: .leading))
                _SplitDivider()
            }
            if let content {
                content
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onPreferenceChange(ColumnWidthKey.self) { if let width = $0 { contentWidth = width } }
                    .transformPreference(NavigationTitleKey.self) { $0 = nil }
                _SplitDivider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .transformPreference(NavigationChromeKey.self) { chrome in
            chrome.hasSidebar = true
            chrome.wantsToolbar = true
            chrome.sidebarWidth = showsSidebar ? sidebarWidth : 0
            chrome.isSidebarVisible = showsSidebar
            chrome.toggleSidebar = {
                withAnimation(.default) {
                    visibility.wrappedValue = visibility.wrappedValue == .detailOnly ? .all : .detailOnly
                }
            }
        }
    }
}

/// NSSplitView's thin divider (black in dark mode).
struct _SplitDivider: View {
    var body: some View {
        Rectangle().fill(Color.splitDivider).frame(width: 1)
    }
}

extension NavigationSplitView where Content == EmptyView {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = nil
        self.detail = detail()
        self.columnVisibility = nil
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = nil
        self.detail = detail()
        self.columnVisibility = columnVisibility
    }
}

/// Legacy NavigationView: behaves like a NavigationStack.
public struct NavigationView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { NavigationStack { content } }
}
