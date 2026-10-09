import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Titles & toolbars (preferences)

public struct NavigationTitleKey: PreferenceKey {
    public static var defaultValue: Text? { nil }
    public static func reduce(value: inout Text?, nextValue: () -> Text?) {
        if let next = nextValue() { value = next }
    }
}

public struct ToolbarItemsKey: PreferenceKey {
    public static var defaultValue: [ToolbarEntry] { [] }
    public static func reduce(value: inout [ToolbarEntry], nextValue: () -> [ToolbarEntry]) {
        value.append(contentsOf: nextValue())
    }
}

public struct ToolbarEntry: Equatable {
    let id: Int
    let placement: ToolbarItemPlacement
    let content: AnyView
    public static func == (lhs: ToolbarEntry, rhs: ToolbarEntry) -> Bool {
        lhs.id == rhs.id && lhs.placement == rhs.placement && GraphComparison.isIdentical(lhs.content, rhs.content)
    }
}

public struct ColumnWidthKey: PreferenceKey {
    public static var defaultValue: CGFloat? { nil }
    public static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

public enum ToolbarItemPlacement: Hashable, Sendable {
    case automatic, principal, navigation, primaryAction, secondaryAction, status, confirmationAction, cancellationAction, destructiveAction, keyboard, bottomBar, topBarLeading, topBarTrailing
}

public struct ToolbarItem<ID, Content: View>: View {
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
    public var body: some View { content }
}

public struct ToolbarItemGroup<Content: View>: View {
    let placement: ToolbarItemPlacement
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
    public var body: some View { HStack { content } }
}

public enum NavigationBarItem { public enum TitleDisplayMode: Sendable { case automatic, inline, large } }

@MainActor private var toolbarIDCounter = 0

extension View {
    public func navigationTitle(_ title: Text) -> some View { preference(key: NavigationTitleKey.self, value: title) }
    public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { preference(key: NavigationTitleKey.self, value: Text(title)) }
    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { preference(key: NavigationTitleKey.self, value: Text(titleKey)) }
    public func navigationSubtitle<S: StringProtocol>(_ subtitle: S) -> some View { self }
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    public func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View { self }

    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        toolbarIDCounter += 1
        return preference(key: ToolbarItemsKey.self, value: [ToolbarEntry(id: toolbarIDCounter, placement: .automatic, content: AnyView(content()))])
    }

    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }

    public func navigationSplitViewColumnWidth(_ width: CGFloat) -> some View {
        preference(key: ColumnWidthKey.self, value: width)
    }

    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        preference(key: ColumnWidthKey.self, value: ideal)
    }
}

public struct ToolbarPlacement: Hashable, Sendable {
    let id: Int
    public static let automatic = ToolbarPlacement(id: 0)
    public static let windowToolbar = ToolbarPlacement(id: 1)
    public static let navigationBar = ToolbarPlacement(id: 2)
}

/// Title + toolbar bar shown by navigation containers.
struct _NavigationBar: View {
    let title: Text?
    let toolbar: [ToolbarEntry]
    let back: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(.borderless)
            }
            if let title { title.font(.headline).lineLimit(1) }
            Spacer(minLength: 8)
            ForEach(toolbar.indices, id: \.self) { index in toolbar[index].content }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
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
    @State private var titles: [Int: Text] = [:]
    @State private var toolbars: [Int: [ToolbarEntry]] = [:]
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
        VStack(spacing: 0) {
            // macOS shows navigation titles in the window title bar; an inline bar appears only for
            // the back button and toolbar items.
            if depth > 0 || !(toolbars[depth] ?? []).isEmpty {
                _NavigationBar(title: depth > 0 ? titles[depth] : nil, toolbar: toolbars[depth] ?? [], back: depth > 0 ? { path.wrappedValue.removeLast() } : nil)
                Divider()
            }
            ZStack(alignment: .topLeading) {
                level(0, content: AnyView(root), depth: depth)
                ForEach(Array(path.wrappedValue.enumerated()), id: \.offset) { index, value in
                    level(index + 1, content: destinations.view(for: value) ?? AnyView(Text("No destination for \(String(describing: value.base))")), depth: depth)
                        .environment(\.dismiss, DismissAction { if path.wrappedValue.count > index { path.wrappedValue.removeLast(path.wrappedValue.count - index) } })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.navigationContext, context)
    }

    private func level(_ index: Int, content: AnyView, depth: Int) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.controlBackground)
            .opacity(index == depth ? 1 : 0)
            .allowsHitTesting(index == depth)
            .onPreferenceChange(NavigationTitleKey.self) { title in titles[index] = title }
            .onPreferenceChange(ToolbarItemsKey.self) { items in toolbars[index] = items }
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
    @State private var sidebarWidth: CGFloat = 220
    @State private var contentWidth: CGFloat = 260
    @State private var detailTitle: Text?
    @State private var detailToolbar: [ToolbarEntry] = []

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar, content: content, detail: detail)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.gray.opacity(0.08))
                .onPreferenceChange(ColumnWidthKey.self) { if let width = $0 { sidebarWidth = width } }
            Divider()
            if let content {
                content
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onPreferenceChange(ColumnWidthKey.self) { if let width = $0 { contentWidth = width } }
                Divider()
            }
            VStack(spacing: 0) {
                if !detailToolbar.isEmpty {
                    _NavigationBar(title: nil, toolbar: detailToolbar, back: nil)
                    Divider()
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onPreferenceChange(NavigationTitleKey.self) { detailTitle = $0 }
                    .onPreferenceChange(ToolbarItemsKey.self) { detailToolbar = $0 }
            }
        }
    }
}

extension NavigationSplitView where Content == EmptyView {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.content = nil
        self.detail = detail()
    }

    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.init(sidebar: sidebar, detail: detail)
    }
}

/// Legacy NavigationView: behaves like a NavigationStack.
public struct NavigationView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { NavigationStack { content } }
}
