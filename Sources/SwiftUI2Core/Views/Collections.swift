import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Wrapping list elements

extension ViewList {
    /// Wraps every element with a modifier built from the element's traits (selection chrome,
    /// segments, tab bar items...).
    @MainActor
    func wrapped<M: ViewModifier>(in subgraph: Subgraph, _ makeModifier: @escaping @MainActor (ViewTraits, Subgraph) -> Attribute<M>) -> ViewList {
        mapElements(in: subgraph) { element in
            var copy = element
            copy.make = { placement in
                let modifier = makeModifier(element.traits, placement.subgraph)
                return M._makeView(modifier: _GraphValue(modifier), inputs: placement) { element.make($0) }
            }
            return copy
        }
    }
}

/// Builds a container from a content view's list, transforming the list first.
struct _ListTransformView<Content: View>: View {
    let content: Content
    let transform: @MainActor (ViewList, _ViewListInputs) -> ViewList
    let layout: AnyLayout

    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs).list
        let transform = AnyAttribute.withoutDependencies { view.attribute.value.transform }
        let transformed = transform(list, inputs.listInputs)
        let layout = view.project(inputs) { $0.layout }
        return inputs.makeLayoutContainer(layout: layout.attribute, list: transformed)
    }
}

extension _ListTransformView: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: _ListTransformView, _ rhs: _ListTransformView) -> Bool {
        MainActor.assumeIsolated { GraphComparison.isIdentical(lhs.content, rhs.content) }
    }
}

// MARK: - Selection

/// A type-erased selection binding shared by List / Picker / TabView.
@MainActor
struct SelectionContext {
    let isSelected: @MainActor (AnyHashable?) -> Bool
    let select: @MainActor (AnyHashable?) -> Void
    let id: ObjectIdentifier?
    /// The selected values (context menus act on them).
    var current: @MainActor () -> [AnyHashable] = { [] }
    /// Command-click: adds or removes a value (multiple selection only).
    var toggle: (@MainActor (AnyHashable) -> Void)?

    static func single<V: Hashable>(_ binding: Binding<V>) -> SelectionContext {
        SelectionContext(
            isSelected: { selectionMatches(AnyHashable(binding.wrappedValue), $0) },
            select: { tag in
                if let value = tag?.base as? V { binding.wrappedValue = value }
                else if let unwrapped = (tag?.base as Any?).flatMap({ $0 as? V }) { binding.wrappedValue = unwrapped }
            },
            id: nil,
            current: { [AnyHashable(binding.wrappedValue)] }
        )
    }

    static func optional<V: Hashable>(_ binding: Binding<V?>) -> SelectionContext {
        SelectionContext(
            isSelected: { tag in binding.wrappedValue.map { selectionMatches(AnyHashable($0), tag) } ?? false },
            select: { tag in binding.wrappedValue = tag?.base as? V },
            id: nil,
            current: { binding.wrappedValue.map { [AnyHashable($0)] } ?? [] }
        )
    }

    static func multiple<V: Hashable>(_ binding: Binding<Set<V>>) -> SelectionContext {
        SelectionContext(
            isSelected: { tag in (tag?.base as? V).map { binding.wrappedValue.contains($0) } ?? false },
            select: { tag in binding.wrappedValue = (tag?.base as? V).map { [$0] } ?? [] },
            id: nil,
            current: { binding.wrappedValue.map { AnyHashable($0) } },
            toggle: { tag in
                guard let value = tag.base as? V else { return }
                if binding.wrappedValue.contains(value) { binding.wrappedValue.remove(value) } else { binding.wrappedValue.insert(value) }
            }
        )
    }
}

// MARK: - List

public enum ListStyleKind: Hashable, Sendable { case automatic, plain, inset, insetGrouped, grouped, sidebar, bordered }

public protocol ListStyle {}
public struct DefaultListStyle: ListStyle { public init() {} }
public struct PlainListStyle: ListStyle { public init() {} }
public struct InsetListStyle: ListStyle {
    var alternatesRowBackgrounds = false
    public init() {}
    public init(alternatesRowBackgrounds: Bool) { self.alternatesRowBackgrounds = alternatesRowBackgrounds }
}
public struct SidebarListStyle: ListStyle { public init() {} }
public struct BorderedListStyle: ListStyle { public init() {} }
extension ListStyle where Self == DefaultListStyle { public static var automatic: DefaultListStyle { .init() } }
extension ListStyle where Self == PlainListStyle { public static var plain: PlainListStyle { .init() } }
extension ListStyle where Self == InsetListStyle {
    public static var inset: InsetListStyle { .init() }
    public static func inset(alternatesRowBackgrounds: Bool) -> InsetListStyle { .init(alternatesRowBackgrounds: alternatesRowBackgrounds) }
}
extension ListStyle where Self == SidebarListStyle { public static var sidebar: SidebarListStyle { .init() } }
extension ListStyle where Self == BorderedListStyle { public static var bordered: BorderedListStyle { .init() } }

struct ListContextKey: EnvironmentKey { static let defaultValue: ListContext? = nil }
struct ListStyleKindKey: EnvironmentKey { static let defaultValue = ListStyleKind.automatic }
struct SidebarColumnKey: EnvironmentKey { static let defaultValue = false }

/// A list style's measured macOS metrics.
enum ResolvedListStyle: Equatable {
    /// The default style: inset rows with separators.
    case automatic
    case inset, plain, bordered, sidebar
    /// The sidebar style inside a split view's sidebar column (no top inset: the column starts
    /// below the toolbar).
    case sidebarColumn

    var hasBackground: Bool { self != .sidebar && self != .sidebarColumn }
    var isSidebar: Bool { self == .sidebar || self == .sidebarColumn }
    /// Rows are at least this tall (content is centered).
    var minRowHeight: CGFloat { isSidebar ? 28 : 24 }
    var showsSeparators: Bool { self == .automatic }
    /// Padding around the rows (inside the background / border).
    var contentInsets: EdgeInsets {
        switch self {
        case .automatic, .inset, .sidebar: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        case .sidebarColumn: EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10)
        case .plain: EdgeInsets()
        case .bordered: EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
        }
    }
    /// Padding inside a row around its content.
    var rowInsets: EdgeInsets {
        switch self {
        case .automatic, .inset, .bordered: EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        case .plain: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        case .sidebar, .sidebarColumn: EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        }
    }
}

@MainActor
struct ListContext {
    let selection: SelectionContext?
    let isForm: Bool
    var style: ResolvedListStyle = .automatic
}

extension ListContext: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: ListContext, _ rhs: ListContext) -> Bool { false }
}

extension EnvironmentValues {
    var listContext: ListContext? {
        get { self[ListContextKey.self] }
        set { self[ListContextKey.self] = newValue }
    }

    /// Controls inside a grouped `Form` use the macOS row style: label leading, control trailing.
    var isInForm: Bool { listContext?.isForm ?? false }

    var listStyleKind: ListStyleKind {
        get { self[ListStyleKindKey.self] }
        set { self[ListStyleKindKey.self] = newValue }
    }

    /// Inside a split view's sidebar column (lists default to the sidebar style).
    var isSidebarColumn: Bool {
        get { self[SidebarColumnKey.self] }
        set { self[SidebarColumnKey.self] = newValue }
    }
}

extension View {
    public func listStyle<S: ListStyle>(_ style: S) -> some View {
        let kind: ListStyleKind
        switch style {
        case is PlainListStyle: kind = .plain
        case is InsetListStyle: kind = .inset
        case is SidebarListStyle: kind = .sidebar
        case is BorderedListStyle: kind = .bordered
        default: kind = .automatic
        }
        let stripes = (style as? InsetListStyle)?.alternatesRowBackgrounds == true
        return environment(\.listStyleKind, kind).transformEnvironment(\.tableStripes) { if stripes { $0 = .enabled } }
    }
}

public enum VerticalEdge: Int8, Hashable, Sendable {
    case top, bottom
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
        public static let all: Set = [.top, .bottom]
    }
}

public struct FormStyleConfiguration {
    public typealias Content = _StyleContent
    public let content: Content
}

@MainActor @preconcurrency
public protocol FormStyle {
    associatedtype Body: View
    typealias Configuration = FormStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// Sections drawn as rounded groups.
public struct GroupedFormStyle: FormStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FormScroll(content: configuration.content, columns: false) }
}

/// Sections without group boxes; rows aligned in a column.
public struct ColumnsFormStyle: FormStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FormScroll(content: configuration.content, columns: true) }
}

public struct AutomaticFormStyle: FormStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _FormScroll(content: configuration.content, columns: false) }
}

struct _FormScroll<Content: View>: View {
    let content: Content
    let columns: Bool
    var body: some View {
        ScrollView {
            _FormStack(content: content)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .environment(\.listContext, ListContext(selection: nil, isForm: true))
        .environment(\.formUsesColumns, columns)
    }
}

struct FormColumnsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var formUsesColumns: Bool {
        get { self[FormColumnsKey.self] }
        set { self[FormColumnsKey.self] = newValue }
    }
}

extension View {
    public func formStyle<S: FormStyle>(_ style: S) -> some View {
        _setStyle(FormStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}
extension FormStyle where Self == GroupedFormStyle { public static var grouped: GroupedFormStyle { .init() } }
extension FormStyle where Self == ColumnsFormStyle { public static var columns: ColumnsFormStyle { .init() } }
extension FormStyle where Self == AutomaticFormStyle { public static var automatic: AutomaticFormStyle { .init() } }

/// Row chrome: padding, full-width hit area, selection highlight, delete context action.
struct _ListRowModifier: ViewModifier {
    let isSelected: Bool
    let select: (@MainActor () -> Void)?
    let background: AnyView?
    let delete: (@MainActor () -> Void)?
    let isForm: Bool
    var style: ResolvedListStyle = .automatic
    var role: ListElementRole = .row
    var position = ListItemPosition()
    var rowInsets: EdgeInsets?
    var partialInsets = _PartialEdgeInsets()
    var separator = ListRowSeparatorConfiguration()
    var sectionSeparator = ListRowSeparatorConfiguration()
    var badge: Text?
    var itemTint: Color?
    var swipeActions: [AnyView] = []
    var reorder: (token: Int, index: Int, move: @MainActor (IndexSet, Int) -> Void)?
    var typeSelect: String?
    var tag: AnyHashable?
    var sectionActions: AnyView?
    var rowSpacing: CGFloat?
    var sectionSpacing: CGFloat?
    var headerProminence = Prominence.standard
    @Environment(\.tableStripes) private var stripes

    func body(content: Content) -> some View {
        if isForm {
            content
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(_OptionalTap(action: select))
                .modifier(_RowContextMenu(swipeActions: swipeActions, delete: delete))
        } else if role == .header {
            header(content)
        } else if role == .sectionGap {
            // Between sections: 20pt; a leading gap stands in for the list's top inset.
            Color.clear.frame(height: position.index == 0 ? style.contentInsets.top : sectionSpacing ?? 20)
        } else {
            let insets = partialInsets.applied(to: rowInsets ?? style.rowInsets)
            let showsBottomSeparator = separator.bottomVisibility == .visible
                || (separator.bottomVisibility == .automatic && style.showsSeparators && role == .row && position.next == .row)
            content
                .tint(itemTint)
                .padding(insets)
                .frame(maxWidth: .infinity, minHeight: style.minRowHeight, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let badge { _ListRowBadge(badge: badge, isSidebar: style.isSidebar).padding(.trailing, insets.trailing) }
                }
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5).fill(Color.listSelection)
                    } else if let background {
                        background
                    } else if stripes == .enabled, role == .row, position.index % 2 == 1 {
                        Color.alternatingRow
                    }
                }
                .overlay(alignment: .bottom) {
                    // Separators between consecutive rows (and below section headers).
                    if showsBottomSeparator {
                        Rectangle().fill(separator.bottomTint ?? Color.separator).frame(height: 1).padding(.horizontal, insets.leading)
                    }
                }
                .overlay(alignment: .top) {
                    if separator.topVisibility == .visible {
                        Rectangle().fill(separator.topTint ?? Color.separator).frame(height: 1).padding(.horizontal, insets.leading)
                    }
                }
                .padding(.top, position.index == 0 ? style.contentInsets.top : 0)
                .padding(.bottom, position.next == .row ? rowSpacing ?? 0 : 0)
                .modifier(_OptionalTap(action: select))
                .modifier(_RowContextMenu(swipeActions: swipeActions, delete: delete))
                .modifier(_OptionalReorder(reorder: reorder))
                .modifier(_TypeSelectRow(text: typeSelect, tag: tag))
        }
    }

    /// Section headers (measured: 11pt semibold; inset lists add 20pt between sections and a
    /// separator below; a leading header is pinned with a full-width line).
    @ViewBuilder private func header(_ content: Content) -> some View {
        headerChrome(content)
            .font(headerProminence == .increased ? .headline : nil)
            .overlay(alignment: .trailing) {
                if let sectionActions {
                    sectionActions.buttonStyle(.borderless).labelStyle(.iconOnly).padding(.trailing, style.rowInsets.trailing)
                }
            }
    }

    @ViewBuilder private func headerChrome(_ content: Content) -> some View {
        let isFirst = position.index == 0
        if style.isSidebar {
            content
                .padding(.horizontal, 4)
                .padding(.top, isFirst ? 10 : 15)
                .padding(.bottom, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
                .padding(.horizontal, style.rowInsets.leading)
                .padding(.top, isFirst ? 7 - style.contentInsets.top : 27)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if sectionSeparator.bottomVisibility == .hidden {
                        EmptyView()
                    } else if style.showsSeparators || sectionSeparator.bottomVisibility == .visible, !isFirst, position.next == .row {
                        Rectangle().fill(sectionSeparator.bottomTint ?? Color.separator).frame(height: 1).padding(.horizontal, style.rowInsets.leading)
                    } else if isFirst, style.hasBackground {
                        Rectangle().fill(Color.separator).frame(height: 1).padding(.horizontal, -style.contentInsets.leading)
                    }
                }
                .padding(.top, isFirst ? style.contentInsets.top : 0)
                .padding(.bottom, isFirst ? 10 : 0)
        }
    }
}

struct _OptionalTap: ViewModifier {
    let action: (@MainActor () -> Void)?
    func body(content: Content) -> some View {
        if let action { content.onTapGesture(perform: action) } else { content }
    }
}

struct _OptionalReorder: ViewModifier {
    let reorder: (token: Int, index: Int, move: @MainActor (IndexSet, Int) -> Void)?
    func body(content: Content) -> some View {
        #if canImport(UniformTypeIdentifiers)
        if let reorder { content.modifier(_RowReorder(token: reorder.token, index: reorder.index, move: reorder.move)) } else { content }
        #else
        content
        #endif
    }
}

struct _OptionalDeleteMenu: ViewModifier {
    let delete: (@MainActor () -> Void)?
    func body(content: Content) -> some View {
        if let delete {
            content.contextMenu { Button("Delete", role: .destructive, action: delete) }
        } else {
            content
        }
    }
}

extension ViewList {
    /// Applies list-row chrome using the environment's list context.
    @MainActor
    func listRows(in subgraph: Subgraph, environment: Attribute<EnvironmentValues>) -> ViewList {
        mapElements(in: subgraph) { element in
            var copy = element
            copy.make = { placement in
                let position = placement.listItemPosition
                let modifier = makeObservedAttribute(placement.subgraph, of: _ListRowModifier.self) {
                    var row = makeListRowModifier(traits: element.traits, environment: environment.value)
                    row.role = element.traits.value(ListElementRoleKey.self)
                    row.position = position?.value ?? ListItemPosition()
                    return row
                }
                return _ListRowModifier._makeView(modifier: _GraphValue(modifier), inputs: placement) { element.make($0) }
            }
            return copy
        }
    }
}

@MainActor
private func makeListRowModifier(traits: ViewTraits, environment: EnvironmentValues) -> _ListRowModifier {
    let context = environment.listContext
    let tag = traits.value(TagTraitKey.self)
    let selection = context?.selection
    var select: (@MainActor () -> Void)?
    if let selection {
        select = { selection.select(tag) }
    }
    if traits.value(SelectionDisabledTraitKey.self) { select = nil }
    var delete: (@MainActor () -> Void)?
    let index = traits.value(DeleteIndexTraitKey.self)
    if let action = traits.value(DeleteActionTraitKey.self), let index, !traits.value(DeleteDisabledTraitKey.self) {
        delete = { action(IndexSet(integer: index)) }
    }
    let isSelected = tag != nil && (selection?.isSelected(tag) ?? false)
    var row = _ListRowModifier(
        isSelected: isSelected,
        select: select,
        background: traits.value(ListRowBackgroundTraitKey.self),
        delete: delete,
        isForm: context?.isForm ?? false,
        style: context?.style ?? .automatic
    )
    row.rowInsets = traits.value(ListRowInsetsTraitKey.self)
    row.partialInsets = traits.value(ListRowPartialInsetsTraitKey.self)
    row.separator = traits.value(ListRowSeparatorTraitKey.self)
    row.sectionSeparator = traits.value(ListSectionSeparatorTraitKey.self)
    row.badge = traits.value(ListBadgeTraitKey.self)
    row.itemTint = traits.value(ListItemTintTraitKey.self)
    row.swipeActions = traits.value(SwipeActionsTraitKey.self)
    if let move = traits.value(MoveActionTraitKey.self), let index, !traits.value(MoveDisabledTraitKey.self) {
        row.reorder = (traits.value(MoveTokenTraitKey.self), index, move)
    }
    row.typeSelect = traits.value(TypeSelectEquivalentTraitKey.self)
    row.tag = tag
    row.sectionActions = traits.value(SectionActionsTraitKey.self)
    row.rowSpacing = environment.listRowSpacing
    row.sectionSpacing = environment.listSectionSpacing
    row.headerProminence = environment.headerProminence
    return row
}

public struct List<SelectionValue: Hashable, Content: View>: View {
    let content: Content
    let selection: SelectionContext?

    @Environment(\.listStyleKind) private var styleKind
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    private var style: ResolvedListStyle {
        switch styleKind {
        case .plain: .plain
        case .inset, .insetGrouped, .grouped: .inset
        case .bordered: .bordered
        case .sidebar: isSidebarColumn ? .sidebarColumn : .sidebar
        case .automatic: isSidebarColumn ? .sidebarColumn : .automatic
        }
    }

    @Environment(\.scrollContentBackground) private var contentBackground
    @State private var typeSelect = TypeSelectRegistry()

    public var body: some View {
        let style = self.style
        let insets = style.contentInsets
        let selection = self.selection
        let typeSelect = self.typeSelect
        // The first row/header carries the top inset (a leading section header is pinned there).
        ScrollView {
            _ListRows(content: content)
                .padding(EdgeInsets(top: 0, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Sidebar rows use the body text style (stacked texts get its leading).
                .transformEnvironment(\.font) { font in if style.isSidebar, font == nil { font = .body } }
        }
        .background(style.hasBackground && contentBackground != .hidden ? Color.controlBackground : Color.clear)
        .overlay {
            if style == .bordered { Rectangle().strokeBorder(Color.listBorder, lineWidth: 1) }
        }
        .environment(\.listContext, ListContext(selection: selection, isForm: false, style: style))
        .environment(\.typeSelectRegistry, typeSelect)
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            // Type-select: typing a row's equivalent selects it.
            guard press.modifiers.isEmpty, let selection, let tag = typeSelect.match(press.characters) else { return .ignored }
            selection.select(tag)
            return .handled
        }
    }
}

/// Rows of a list (top-level rows get row chrome; sections apply their own).
struct _ListRows<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var listInputs = inputs.listInputs
        listInputs.flattensSections = true
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: listInputs).list
        let rows = list.listRows(in: inputs.subgraph, environment: inputs.environment)
        // Lists are lazy: only rows near the visible area are built.
        let leading = HorizontalAlignment.leading
        return inputs.makeLazyStack(axis: .vertical, crossGuide: (leading.key, leading.id), spacing: 0, list: rows, eagerLayout: inputs.constant(_VStackLayout(alignment: .leading, spacing: 0)))
    }
}

extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = nil
    }
}

extension List {
    public init(selection: Binding<SelectionValue?>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection.map { .optional($0) }
    }

    @_disfavoredOverload public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = .single(selection)
    }

    public init(selection: Binding<Set<SelectionValue>>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection.map { .multiple($0) }
    }
}

extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, selection: Binding<SelectionValue?>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
        self.selection = .optional(selection)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(_ data: Data, id: KeyPath<Data.Element, ID>, selection: Binding<SelectionValue?>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, ID, RowContent> {
        self.content = ForEach(data, id: id, content: rowContent)
        self.selection = .optional(selection)
    }
}

extension List where SelectionValue == Never {
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.content = ForEach(data, content: rowContent)
        self.selection = nil
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == ForEach<Data, ID, RowContent> {
        self.content = ForEach(data, id: id, content: rowContent)
        self.selection = nil
    }
}

public enum DeleteIndexTraitKey: _ViewTraitKey {
    public static var defaultValue: Int? { nil }
}

// MARK: - onDelete / onMove (DynamicViewContent)

@MainActor
extension ForEach where Content: View {
    /// Adds a delete action (offered as a row context menu item inside List / Form).
    public func onDelete(perform action: (@MainActor (IndexSet) -> Void)?) -> _DeletableForEach<Data, ID, Content> {
        _DeletableForEach(base: self, action: action)
    }

    /// Rows can be dragged to reorder them inside List.
    public func onMove(perform action: (@MainActor (IndexSet, Int) -> Void)?) -> _DeletableForEach<Data, ID, Content> {
        _DeletableForEach(base: self, action: nil, moveAction: action)
    }
    public func onInsert(of types: [String], perform action: @escaping (Int, [Any]) -> Void) -> ForEach { self }
}

public struct _DeletableForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    let base: ForEach<Data, ID, Content>
    let action: (@MainActor (IndexSet) -> Void)?
    var moveAction: (@MainActor (IndexSet, Int) -> Void)?

    public var body: Never { primitiveBody(Self.self) }

    public func onMove(perform action: (@MainActor (IndexSet, Int) -> Void)?) -> _DeletableForEach {
        var copy = self
        copy.moveAction = action
        return copy
    }

    public func onDelete(perform action: (@MainActor (IndexSet) -> Void)?) -> _DeletableForEach {
        _DeletableForEach(base: base, action: action, moveAction: moveAction)
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let base = ForEach<Data, ID, Content>._makeViewList(view: view.project(inputs) { $0.base }, inputs: inputs).list
        let action = Attribute<(@MainActor (IndexSet) -> Void)?>(inputs.subgraph) { view.attribute.value.action }
        let moveAction = Attribute<(@MainActor (IndexSet, Int) -> Void)?>(inputs.subgraph) { view.attribute.value.moveAction }
        let token = Attribute<Int>(inputs.subgraph, value: ObjectIdentifier(moveAction).hashValue)
        let forEach = view.project(inputs) { $0.base }
        let list = base.mapElements(in: inputs.subgraph) { element in
            var copy = element
            copy.traits[DeleteActionTraitKey.self] = action
            copy.traits[MoveActionTraitKey.self] = moveAction
            copy.traits[MoveTokenTraitKey.self] = token
            if let tag = element.traits[TagTraitKey.self] {
                copy.traits[DeleteIndexTraitKey.self] = Attribute<Int?>(inputs.subgraph) {
                    let current = forEach.attribute.value
                    let target = tag.value
                    return current.data.indices.firstIndex { AnyHashable(current.identify(current.data[$0])) == target }
                        .map { current.data.distance(from: current.data.startIndex, to: current.data.indices[$0]) }
                }
            }
            return copy
        }
        return _ViewListOutputs(list: list)
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeUnary(list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

// MARK: - Form & Section

public struct Form<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        _StyledView(configuration: FormStyleConfiguration(content: _StyleContent(content))) {
            AnyView(AutomaticFormStyle().makeBody(configuration: $0))
        }
    }
}

/// The form's sections, stacked (each section stays one grouped element).
struct _FormStack<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var listInputs = inputs.listInputs
        listInputs.groupsSections = true
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: listInputs).list
        return inputs.makeUnary(list: list, layout: _VStackLayout(alignment: .leading, spacing: 30))
    }
}

public struct Section<Parent: View, Content: View, Footer: View>: View {
    let header: Parent?
    let content: Content
    let footer: Footer?
    @Environment(\.listContext) private var listContext
    @Environment(\.formUsesColumns) private var formUsesColumns

    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    /// In lists, a section contributes its header, rows and footer as separate list elements.
    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        // Forms draw each section as a group; elsewhere (lists, stacks) a section contributes
        // its header, content and footer as separate children.
        if inputs.groupsSections { return .unaryElement(view: view, inputs: inputs) }
        if !inputs.flattensSections {
            let (hasHeader, hasFooter) = AnyAttribute.withoutDependencies { (view.attribute.value.header != nil, view.attribute.value.footer != nil) }
            var nodes: [ViewList.Node] = []
            if hasHeader {
                nodes.append(.nested(.index(0), Parent?._makeViewList(view: view.project(inputs) { $0.header }, inputs: inputs).list))
            }
            nodes.append(.nested(.index(1), Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs).list))
            if hasFooter {
                nodes.append(.nested(.index(2), Footer?._makeViewList(view: view.project(inputs) { $0.footer }, inputs: inputs).list))
            }
            return _ViewListOutputs(list: ViewList(nodes: nodes))
        }
        let (hasHeader, hasFooter) = AnyAttribute.withoutDependencies { (view.attribute.value.header != nil, view.attribute.value.footer != nil) }
        var nodes: [ViewList.Node] = []
        func element<V: View>(_ role: ListElementRole, _ project: @escaping (Self) -> V) -> ViewList.Node {
            var traits = ViewTraits()
            traits[ListElementRoleKey.self] = Attribute(inputs.subgraph, value: role)
            return .element(ViewListElement(traits: traits) { placement in
                V._makeView(view: view.project(inputs) { project($0) }, inputs: inputs.instantiate(placement))
            })
        }
        // Sections without a header are still separated (an empty spacer element).
        if hasHeader {
            if inputs.rawSectionHeaders {
                nodes.append(element(.header) { $0.header })
            } else {
                nodes.append(element(.header) { _ListSectionHeader(content: $0.header) })
            }
        } else {
            nodes.append(element(.sectionGap) { _ in EmptyView() })
        }
        let rows = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs).list
        nodes.append(.nested(.index(1), rows))
        if hasFooter { nodes.append(element(.footer) { $0.footer }) }
        return _ViewListOutputs(list: ViewList(nodes: nodes))
    }

    public var body: some View {
        if listContext?.isForm == true, !formUsesColumns {
            // Grouped form section (macOS 26): bold header, rounded card with a hairline border,
            // trailing footer; 10pt between them and from the card edges.
            VStack(alignment: .leading, spacing: 10) {
                if let header {
                    header.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
                }
                _FormRows(content: content)
                    .background(Color.formSeparator)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6).fill(Color.formCard)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.formCardBorder, lineWidth: 0.5))
                    }
                if let footer {
                    footer.font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 10)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let header {
                    header.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, listContext?.isForm == true ? 4 : 8)
                }
                if listContext?.isForm == true {
                    _FormRows(content: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    _ListRows(content: content)
                }
                if let footer {
                    footer.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }
            .padding(.bottom, listContext == nil ? 0 : 6)
        }
    }
}

/// Section header text style in lists (11pt semibold; secondary, tertiary in sidebars).
struct _ListSectionHeader<Content: View>: View {
    let content: Content
    @Environment(\.listContext) private var context

    var body: some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(context?.style.isSidebar == true ? HierarchicalShapeStyle.tertiary : .secondary)
    }
}

/// Form rows: one per element with dividers between them.
struct _FormRows<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs).list
        let rows = list.wrapped(in: inputs.subgraph) { _, subgraph in
            Attribute<_FormRowModifier>(subgraph, value: _FormRowModifier())
        }
        return inputs.makeLayoutContainer(layout: inputs.constant(_VStackLayout(alignment: .leading, spacing: 1)), list: rows)
    }
}

/// A grouped form row (macOS 26 metrics): 10pt above and below the content, on the card color;
/// the 1pt gaps between rows show the separator color behind them.
struct _FormRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.formCard)
    }
}

extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.header = nil
        self.content = content()
        self.footer = nil
    }
}

extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.header = header()
        self.content = content()
        self.footer = nil
    }
}

extension Section where Parent == Text, Footer == EmptyView {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.header = Text(title)
        self.content = content()
        self.footer = nil
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.header = Text(titleKey)
        self.content = content()
        self.footer = nil
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.header = Text(title)
        self.content = content()
        self.footer = nil
    }
}

// MARK: - Picker

public enum PickerStyleKind: Hashable, Sendable { case automatic, menu, segmented, radioGroup, inline, wheel, palette, navigationLink }

public protocol PickerStyle {}
public struct DefaultPickerStyle: PickerStyle { public init() {} }
public struct MenuPickerStyle: PickerStyle { public init() {} }
public struct SegmentedPickerStyle: PickerStyle { public init() {} }
public struct RadioGroupPickerStyle: PickerStyle { public init() {} }
public struct InlinePickerStyle: PickerStyle { public init() {} }
public struct WheelPickerStyle: PickerStyle { public init() {} }
public struct PalettePickerStyle: PickerStyle { public init() {} }
extension PickerStyle where Self == DefaultPickerStyle { public static var automatic: DefaultPickerStyle { .init() } }
extension PickerStyle where Self == MenuPickerStyle { public static var menu: MenuPickerStyle { .init() } }
extension PickerStyle where Self == SegmentedPickerStyle { public static var segmented: SegmentedPickerStyle { .init() } }
extension PickerStyle where Self == RadioGroupPickerStyle { public static var radioGroup: RadioGroupPickerStyle { .init() } }
extension PickerStyle where Self == InlinePickerStyle { public static var inline: InlinePickerStyle { .init() } }
extension PickerStyle where Self == WheelPickerStyle { public static var wheel: WheelPickerStyle { .init() } }
extension PickerStyle where Self == PalettePickerStyle { public static var palette: PalettePickerStyle { .init() } }

struct PickerStyleKey: EnvironmentKey { static let defaultValue = PickerStyleKind.automatic }

extension EnvironmentValues {
    var pickerStyle: PickerStyleKind {
        get { self[PickerStyleKey.self] }
        set { self[PickerStyleKey.self] = newValue }
    }
}

extension View {
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View {
        let kind: PickerStyleKind
        switch style {
        case is MenuPickerStyle: kind = .menu
        case is SegmentedPickerStyle, is PalettePickerStyle: kind = .segmented
        case is RadioGroupPickerStyle: kind = .radioGroup
        case is InlinePickerStyle: kind = .inline
        case is WheelPickerStyle: kind = .menu
        default: kind = .automatic
        }
        return environment(\.pickerStyle, kind)
    }
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    let selection: Binding<SelectionValue>
    let label: Label
    let content: Content
    @Environment(\.pickerStyle) private var style
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm
    @State private var menuPresented = false

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.content = content()
        self.label = label()
    }

    /// The older label-first form (`Picker(selection:label:content:)`).
    public init(selection: Binding<SelectionValue>, label: Label, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
        self.label = label
    }

    public var body: some View {
        if isInForm, !labelsHidden, style != .radioGroup, style != .inline, style != .segmented {
            // Grouped form row: label leading, a borderless pop-up trailing.
            _FormLabeledRow { label } control: { selector }
        } else {
            HStack(alignment: style == .radioGroup || style == .inline ? .firstTextBaseline : .center, spacing: 8) {
                if !labelsHidden {
                    label
                    if isInForm { Spacer(minLength: 8) }
                }
                selector
            }
        }
    }

    @ViewBuilder private var selector: some View {
        let context = SelectionContext.single(selection)
            switch style {
            case .segmented:
                _ListTransformView(content: content, transform: { list, inputs in
                    list.wrapped(in: inputs.subgraph) { traits, subgraph in
                        makeObservedAttribute(subgraph, of: _SegmentModifier.self) {
                            let tag = traits.value(TagTraitKey.self)
                            return _SegmentModifier(isSelected: context.isSelected(tag), select: { context.select(tag) })
                        }
                    }
                }, layout: AnyLayout(_SegmentedLayout()))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.segmentedTrack))
            case .radioGroup, .inline:
                _ListTransformView(content: content, transform: { list, inputs in
                    list.wrapped(in: inputs.subgraph) { traits, subgraph in
                        makeObservedAttribute(subgraph, of: _RadioModifier.self) {
                            let tag = traits.value(TagTraitKey.self)
                            return _RadioModifier(isSelected: context.isSelected(tag), select: { context.select(tag) })
                        }
                    }
                }, layout: isInForm ? AnyLayout(_HStackLayout(spacing: 12)) : AnyLayout(_VStackLayout(alignment: .leading, spacing: 4)))
            default:
                Button { menuPresented = true } label: {
                    HStack(spacing: 7.5) {
                        _ListTransformView(content: content, transform: { list, inputs in
                            list.filtered(in: inputs.subgraph) { AnyHashable(selection.wrappedValue) }
                        }, layout: AnyLayout(_ZStackLayout(alignment: .leading)))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .modifier(_PickerButtonStyle(borderless: isInForm))
                .modifier(_SheetModifier(isPresented: $menuPresented, onDismiss: nil, content: {
                    _ListTransformView(content: content, transform: { list, inputs in
                        list.wrapped(in: inputs.subgraph) { traits, subgraph in
                            makeObservedAttribute(subgraph, of: _MenuOptionModifier.self) {
                                let tag = traits.value(TagTraitKey.self)
                                return _MenuOptionModifier(isSelected: context.isSelected(tag), select: { context.select(tag) })
                            }
                        }
                    }, layout: AnyLayout(_VStackLayout(alignment: .leading, spacing: 0)))
                    .frame(minWidth: 140, alignment: .leading)
                }, kind: .menu))
            }
    }
}

/// Pop-up pickers are bordered, except in grouped forms (a borderless 16pt pop-up).
struct _PickerButtonStyle: ViewModifier {
    let borderless: Bool
    func body(content: Content) -> some View {
        if borderless {
            content.buttonStyle(.plain).frame(height: 16)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension Picker where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(titleKey) }
    }
}

struct _SegmentModifier: ViewModifier {
    let isSelected: Bool
    let select: @MainActor () -> Void
    func body(content: Content) -> some View {
        // macOS segmented control: 22pt tall segments, the selected one filled.
        content
            .padding(.horizontal, 7.25)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.segmentedSelection : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
    }
}

struct _RadioModifier: ViewModifier {
    let isSelected: Bool
    let select: @MainActor () -> Void
    func body(content: Content) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().strokeBorder(Color.gray, lineWidth: 1)
                if isSelected { Circle().fill(Color.accentColor).padding(3) }
            }
            .frame(width: 14, height: 14)
            content
        }
        .onTapGesture(perform: select)
    }
}

struct _MenuOptionModifier: ViewModifier {
    let isSelected: Bool
    let select: @MainActor () -> Void
    @Environment(\.buttonDismissAction) private var dismiss
    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(isSelected ? 1 : 0)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture {
            select()
            dismiss?()
        }
    }
}

// MARK: - TabView

public struct TabView<SelectionValue: Hashable, Content: View>: View {
    let selection: Binding<SelectionValue>?
    let content: Content
    @State private var internalSelection: AnyHashable?
    @Environment(\.tabViewStyle) private var style

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    public var body: some View {
        let context: SelectionContext
        if let selection {
            context = .single(selection)
        } else {
            let binding = $internalSelection
            context = SelectionContext(isSelected: { tag in
                guard let current = binding.wrappedValue else { return false }
                return selectionMatches(current, tag)
            }, select: { binding.wrappedValue = $0 }, id: nil)
        }
        let current: @MainActor () -> AnyHashable? = {
            if let selection { return AnyHashable(selection.wrappedValue) }
            return internalSelection
        }
        let binding = $internalSelection
        let sidebar = style == .sidebarAdaptable
        let items = _ListTransformView(content: content, transform: { list, inputs in
            list.wrapped(in: inputs.subgraph) { traits, subgraph in
                makeObservedAttribute(subgraph, of: _TabItemModifier.self) {
                    let tag = traits.value(TagTraitKey.self)
                    return _TabItemModifier(label: traits.value(TabItemTraitKey.self), isSelected: context.isSelected(tag), select: { context.select(tag) }, adoptIfUnset: {
                        if selection == nil, binding.wrappedValue == nil, let tag { binding.wrappedValue = tag }
                    }, isSidebarRow: sidebar)
                }
            }
        }, layout: sidebar ? AnyLayout(_VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(_HStackLayout(spacing: 4)))
        let pages = _ListTransformView(content: content, transform: { list, inputs in
            list.filtered(in: inputs.subgraph, selection: current)
        }, layout: AnyLayout(_ZStackLayout(alignment: .topLeading)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        return Group {
            if sidebar {
                // macOS 15 sidebar-adaptable tab views list their tabs in a sidebar.
                HStack(spacing: 0) {
                    items
                        .padding(10)
                        .frame(width: 180, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    pages
                }
            } else {
                VStack(spacing: 0) {
                    items
                        .padding(.vertical, 6)
                        .padding(.horizontal, style == .grouped ? 4 : 0)
                        .background(style == .grouped ? RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)) : nil)
                        .padding(.top, style == .grouped ? 6 : 0)
                    if style != .grouped { Divider() }
                    pages
                }
            }
        }
    }
}

extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) {
        self.selection = nil
        self.content = content()
    }
}

/// Renders an element's `.tabItem` label as a tab bar button (the element's content itself is not
/// shown in the tab bar).
struct _TabItemModifier: ViewModifier {
    let label: AnyView?
    let isSelected: Bool
    let select: @MainActor () -> Void
    let adoptIfUnset: @MainActor () -> Void
    var isSidebarRow = false

    func body(content: Content) -> some View {
        (label ?? AnyView(Text("Tab")))
            .labelStyle(TitleAndIconLabelStyle())
            .padding(.horizontal, isSidebarRow ? 8 : 10)
            .padding(.vertical, 4)
            .frame(maxWidth: isSidebarRow ? .infinity : nil, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? (isSidebarRow ? Color.listSelection : Color.accentColor.opacity(0.2)) : Color.clear))
            .foregroundStyle(isSelected && !isSidebarRow ? Color.accentColor : Color.primary)
            .onTapGesture(perform: select)
            .onAppear(perform: adoptIfUnset)
    }
}

/// iOS 18 style `Tab("Title", systemImage:, value:) { content }`.
/// What a tab is for (`.search` tabs hold the search UI).
public struct TabRole: Hashable, Sendable {
    let value: Int
    public static let search = TabRole(value: 0)
}

public struct Tab<Value: Hashable, Content: View>: View {
    let title: Text?
    let systemImage: String?
    let image: String?
    let value: Value?
    let role: TabRole?
    let content: Content

    init(title: Text?, systemImage: String?, image: String? = nil, value: Value?, role: TabRole?, content: Content) {
        self.title = title
        self.systemImage = systemImage
        self.image = image
        self.value = value
        self.role = role
        self.content = content
    }

    public init(_ titleKey: LocalizedStringKey, systemImage: String, value: Value, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: Text(titleKey), systemImage: systemImage, value: value, role: role, content: content())
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, value: Value, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: Text(title), systemImage: systemImage, value: value, role: role, content: content())
    }

    public init(_ titleKey: LocalizedStringKey, image: String, value: Value, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: Text(titleKey), systemImage: nil, image: image, value: value, role: role, content: content())
    }

    public init(value: Value, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: nil, systemImage: role == .search ? "magnifyingglass" : nil, value: value, role: role, content: content())
    }

    public var body: some View {
        content
            .tabItem {
                if let systemImage, let title { Label { title } icon: { Image(systemName: systemImage) } }
                else if let image, let title { Label { title } icon: { Image(image) } }
                else if let title { title }
                else if let systemImage { Image(systemName: systemImage) }
            }
            .modifier(_OptionalTag(value: value))
    }
}

/// Tabs of a TabView without a selection (identified by position).
extension Tab where Value == Never {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: Text(titleKey), systemImage: systemImage, value: nil, role: role, content: content())
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, role: TabRole? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: Text(title), systemImage: systemImage, value: nil, role: role, content: content())
    }

    public init(role: TabRole?, @ViewBuilder content: () -> Content) {
        self.init(title: nil, systemImage: role == .search ? "magnifyingglass" : nil, value: nil, role: role, content: content())
    }
}

struct _OptionalTag<Value: Hashable>: ViewModifier {
    let value: Value?
    func body(content: Content) -> some View {
        if let value { content.tag(value) } else { content }
    }
}

/// Groups tabs (sidebar-adaptable tab views show them under a header; others flatten them).
public struct TabSection<Header: View, Content: View, Footer: View>: View {
    let header: Header
    let content: Content
    let footer: Footer

    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    public var body: some View { content }
}

extension TabSection where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension TabSection where Header == Text, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(titleKey) }, footer: { EmptyView() })
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

// MARK: - Grid

enum GridRowTraitKey: _ViewTraitKey {
    static var defaultValue: Int? { nil }
}

public struct GridRow<Content: View>: View {
    let alignment: VerticalAlignment?
    let content: Content

    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs).list
        GridRowCounter.value += 1
        let row = Attribute<Int?>(inputs.subgraph, value: GridRowCounter.value)
        return _ViewListOutputs(list: list.mapElements(in: inputs.subgraph) { element in
            var copy = element
            copy.traits[GridRowTraitKey.self] = row
            return copy
        })
    }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        inputs.makeLayoutContainer(layout: inputs.constant(_HStackLayout()), list: _makeViewList(view: view, inputs: inputs.listInputs).list)
    }
}

public struct Grid<Content: View>: View {
    let alignment: Alignment
    let horizontalSpacing: CGFloat?
    let verticalSpacing: CGFloat?
    let content: Content

    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }

    public var body: some View {
        _GridLayout(alignment: alignment, horizontalSpacing: horizontalSpacing ?? 8, verticalSpacing: verticalSpacing ?? 8) { content }
    }
}

/// Lays out cells by `GridRow` membership: column widths are the max of their cells, row heights
/// the max of the row; views outside a row span all columns.
struct _GridLayout: Layout, Equatable {
    let alignment: Alignment
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private struct Row {
        var cells: [(index: Int, span: Int, unsizedWidth: Bool)] = []
        var isFullWidth = false
    }

    private func rows(_ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var lastRowID: Int?? = .none
        for index in subviews.indices {
            let traits = subviews[index].traits
            let rowID = traits.value(GridRowTraitKey.self)
            let span = max(1, traits.value(GridCellColumnsTraitKey.self))
            let unsized = traits.value(GridCellUnsizedAxesTraitKey.self).contains(.horizontal)
            if let rowID {
                if lastRowID != .some(rowID) { rows.append(Row()) }
                rows[rows.count - 1].cells.append((index, span, unsized))
            } else {
                rows.append(Row(cells: [(index, 1, true)], isFullWidth: true))
            }
            lastRowID = .some(rowID)
        }
        return rows
    }

    private func measure(_ subviews: Subviews) -> (rows: [Row], widths: [CGFloat], heights: [CGFloat]) {
        let rows = rows(subviews)
        let columns = rows.filter { !$0.isFullWidth }.map { $0.cells.reduce(0) { $0 + $1.span } }.max() ?? 1
        var widths = Array(repeating: CGFloat(0), count: max(columns, 1))
        var heights: [CGFloat] = []
        for row in rows {
            var column = 0
            var height: CGFloat = 0
            for cell in row.cells {
                let size = subviews[cell.index].sizeThatFits(cell.unsizedWidth ? ProposedViewSize(width: 0, height: nil) : .unspecified)
                if !row.isFullWidth, cell.span == 1, !cell.unsizedWidth, column < widths.count { widths[column] = max(widths[column], size.width) }
                height = max(height, size.height)
                column += cell.span
            }
            heights.append(height)
        }
        return (rows, widths, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let (rows, widths, heights) = measure(subviews)
        let width = widths.reduce(0, +) + horizontalSpacing * CGFloat(max(widths.count - 1, 0))
        let height = heights.reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let (rows, widths, heights) = measure(subviews)
        let totalWidth = widths.reduce(0, +) + horizontalSpacing * CGFloat(max(widths.count - 1, 0))
        var y = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            var x = bounds.minX
            var column = 0
            for cell in row.cells {
                let cellWidth: CGFloat
                if row.isFullWidth {
                    cellWidth = totalWidth
                } else {
                    let end = min(column + cell.span, widths.count)
                    cellWidth = widths[column..<end].reduce(0, +) + horizontalSpacing * CGFloat(max(end - column - 1, 0))
                }
                let proposalSize = ProposedViewSize(width: cellWidth, height: heights[rowIndex])
                let size = subviews[cell.index].sizeThatFits(proposalSize)
                let dx: CGFloat
                switch alignment.horizontal {
                case .leading: dx = 0
                case .trailing: dx = cellWidth - size.width
                default: dx = (cellWidth - size.width) / 2
                }
                let dy: CGFloat = alignment.vertical == .top ? 0 : alignment.vertical == .bottom ? heights[rowIndex] - size.height : (heights[rowIndex] - size.height) / 2
                subviews[cell.index].place(at: CGPoint(x: x + dx, y: y + dy), proposal: proposalSize)
                x += cellWidth + horizontalSpacing
                column += cell.span
            }
            y += heights[rowIndex] + verticalSpacing
        }
    }
}

// MARK: - Lazy grids

public struct GridItem: Sendable, Hashable {
    public enum Size: Sendable, Hashable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }

    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }

    public static func == (lhs: GridItem, rhs: GridItem) -> Bool { lhs.size == rhs.size && lhs.spacing == rhs.spacing }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(size)
        hasher.combine(spacing)
    }
}

extension GridItem: @unchecked Sendable {}

/// Lazy grid layout (laid out eagerly). Tracks follow SwiftUI: fixed items take their size; the
/// rest of the width (after the items' spacing) is shared equally by flexible items (clamped to
/// their range) and adaptive items (split into as many tracks of at least their minimum as fit).
/// Section headers and footers span the grid. The grid is as wide as its tracks.
struct _LazyGridLayout: Layout {
    let items: [GridItem]
    let spacing: CGFloat
    let axis: Axis
    var alignment: Alignment = .center

    struct Track { var size: CGFloat; var gap: CGFloat; var alignment: Alignment? }

    func tracks(available: CGFloat) -> [Track] {
        let gaps = items.map { $0.spacing ?? 8 }
        var remaining = available - gaps.dropLast().reduce(0, +)
        var shared = 0
        for item in items {
            if case .fixed(let value) = item.size { remaining -= value } else { shared += 1 }
        }
        let share = shared > 0 ? max(0, remaining / CGFloat(shared)) : 0
        var result: [Track] = []
        for (index, item) in items.enumerated() {
            let gap = gaps[index]
            switch item.size {
            case .fixed(let value):
                result.append(Track(size: value, gap: gap, alignment: item.alignment))
            case let .flexible(minimum, maximum):
                result.append(Track(size: min(max(share, minimum), maximum), gap: gap, alignment: item.alignment))
            case let .adaptive(minimum, maximum):
                let count = max(1, Int(((share + gap) / (minimum + gap)).rounded(.down)))
                let width = min(maximum, max(minimum, (share - gap * CGFloat(count - 1)) / CGFloat(count)))
                for _ in 0..<count { result.append(Track(size: width, gap: gap, alignment: item.alignment)) }
            }
        }
        return result
    }

    /// Lazy grids are containers, not text: standard spacing around them.
    func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing { .default }

    static func fraction(_ guide: HorizontalAlignment) -> CGFloat {
        guide == .leading ? 0 : guide == .trailing ? 1 : 0.5
    }

    static func fraction(_ guide: VerticalAlignment) -> CGFloat {
        guide == .top ? 0 : guide == .bottom ? 1 : 0.5
    }

    private func crossSize(_ tracks: [Track]) -> CGFloat {
        tracks.map(\.size).reduce(0, +) + tracks.dropLast().map(\.gap).reduce(0, +)
    }

    private func isFullLine(_ subview: LayoutSubview) -> Bool {
        let role = subview.traits.value(ListElementRoleKey.self)
        return role == .header || role == .footer
    }

    /// Lines of subview indices (a header/footer is a line by itself).
    private func lines(_ subviews: Subviews, columns: Int) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for index in subviews.indices {
            if MainActor.assumeIsolated({ isFullLine(subviews[index]) }) {
                if !current.isEmpty { result.append(current); current = [] }
                result.append([index])
            } else {
                current.append(index)
                if current.count == columns { result.append(current); current = [] }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let available = proposal[axis.other].flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(items.count) * 80
        let tracks = tracks(available: available)
        guard !tracks.isEmpty else { return .zero }
        let cross = crossSize(tracks)
        var main: CGFloat = 0
        let allLines = lines(subviews, columns: tracks.count)
        for line in allLines {
            var lineSize: CGFloat = 0
            for (column, index) in line.enumerated() {
                let full = line.count == 1 && MainActor.assumeIsolated { isFullLine(subviews[index]) }
                let size = subviews[index].sizeThatFits(ProposedViewSize(main: nil, cross: full ? cross : tracks[column].size, axis: axis))
                lineSize = max(lineSize, size[axis])
            }
            main += lineSize
        }
        main += spacing * CGFloat(max(allLines.count - 1, 0))
        return CGSize(main: main, cross: cross, axis: axis)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Tracks come from the proposed width (the grid itself is only as wide as its tracks).
        let tracks = tracks(available: proposal[axis.other].flatMap { $0.isFinite ? $0 : nil } ?? bounds.size[axis.other])
        guard !tracks.isEmpty else { return }
        let cross = crossSize(tracks)
        // The tracks are centered in the bounds.
        let crossStart = bounds.origin[axis.other] + max(0, (bounds.size[axis.other] - cross) / 2)
        var position = bounds.origin[axis]
        for line in lines(subviews, columns: tracks.count) {
            let full = line.count == 1 && MainActor.assumeIsolated { isFullLine(subviews[line[0]]) }
            let proposals = line.enumerated().map { column, _ in ProposedViewSize(main: nil, cross: full ? cross : tracks[column].size, axis: axis) }
            let sizes = zip(line, proposals).map { subviews[$0].sizeThatFits($1) }
            let lineSize = sizes.map { $0[axis] }.max() ?? 0
            var crossPosition = crossStart
            for (column, index) in line.enumerated() {
                let size = sizes[column]
                let slot = full ? cross : tracks[column].size
                let cellAlignment = full ? alignment : (tracks[column].alignment ?? alignment)
                let unit = axis == .vertical ? Self.fraction(cellAlignment.horizontal) : Self.fraction(cellAlignment.vertical)
                let crossOffset = (slot - size[axis.other]) * unit
                let mainOffset = (lineSize - size[axis]) / 2
                let point = axis == .vertical
                    ? CGPoint(x: crossPosition + crossOffset, y: position + mainOffset)
                    : CGPoint(x: position + mainOffset, y: crossPosition + crossOffset)
                subviews[index].place(at: point, proposal: ProposedViewSize(main: size[axis], cross: slot, axis: axis))
                if !full { crossPosition += tracks[column].size + tracks[column].gap }
            }
            position += lineSize + spacing
        }
    }
}

/// The grid's children with section headers/footers as their own elements.
struct _LazyGridView<Content: View>: View {
    let layout: _LazyGridLayout
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var listInputs = inputs.listInputs
        listInputs.flattensSections = true
        listInputs.rawSectionHeaders = true
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: listInputs).list
        let layout = Attribute<_LazyGridLayout>(inputs.subgraph) { view.attribute.value.layout }
        return inputs.makeLayoutContainer(layout: layout, list: list)
    }
}

public struct LazyVGrid<Content: View>: View {
    let columns: [GridItem]
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        _LazyGridView(layout: _LazyGridLayout(items: columns, spacing: spacing ?? 8, axis: .vertical, alignment: Alignment(horizontal: alignment, vertical: .center)), content: content)
    }
}

public struct LazyHGrid<Content: View>: View {
    let rows: [GridItem]
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        _LazyGridView(layout: _LazyGridLayout(items: rows, spacing: spacing ?? 8, axis: .horizontal, alignment: Alignment(horizontal: .center, vertical: alignment)), content: content)
    }
}

public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 2)
}

// MARK: - ViewThatFits

public struct ViewThatFits<Content: View>: View {
    let axes: Axis.Set
    let content: Content

    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public var body: some View {
        _ViewThatFitsLayout(axes: axes) { content }
    }
}

/// Shows the first child whose ideal size fits the proposal along `axes`; the others are hidden.
struct _ViewThatFitsLayout: Layout, Equatable {
    let axes: Axis.Set

    private func choice(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Int? {
        guard !subviews.isEmpty else { return nil }
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let fitsWidth = !axes.contains(.horizontal) || ideal.width <= (proposal.width ?? .infinity)
            let fitsHeight = !axes.contains(.vertical) || ideal.height <= (proposal.height ?? .infinity)
            if fitsWidth && fitsHeight { return index }
        }
        return subviews.count - 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let index = choice(proposal, subviews) else { return .zero }
        return subviews[index].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let chosen = choice(proposal, subviews)
        for index in subviews.indices {
            if index == chosen {
                subviews[index].place(at: bounds.origin, proposal: proposal)
            } else {
                subviews[index].hide()
            }
        }
    }
}

// MARK: - Searchable

extension View {
    public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil) -> some View {
        _Searchable(content: self, text: text, isPresented: nil, prompt: prompt?.plainString ?? "Search")
    }

    @_disfavoredOverload public func searchable<S: StringProtocol>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: S) -> some View {
        searchable(text: text, placement: placement, prompt: Text(prompt))
    }

    public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey) -> some View {
        searchable(text: text, placement: placement, prompt: Text(prompt))
    }

    /// `isPresented` follows (and drives) whether the search field is active.
    public func searchable(text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil) -> some View {
        _Searchable(content: self, text: text, isPresented: isPresented, prompt: prompt?.plainString ?? "Search")
    }

    @_disfavoredOverload public func searchable<S: StringProtocol>(text: Binding<String>, isPresented: Binding<Bool>, placement: SearchFieldPlacement = .automatic, prompt: S) -> some View {
        searchable(text: text, isPresented: isPresented, placement: placement, prompt: Text(prompt))
    }

    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View { self }
}

public struct SearchFieldPlacement: Sendable {
    public static let automatic = SearchFieldPlacement()
    public static let toolbar = SearchFieldPlacement()
    public static let sidebar = SearchFieldPlacement()
}

@MainActor
enum GridRowCounter {
    static var value = 0
}

/// Segmented control layout: equal-width segments filling the offered width (ideal: widest × n).
struct _SegmentedLayout: Layout, Equatable {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count)
        var width = ideal
        if let proposed = proposal.width, proposed.isFinite { width = max(proposed, ideal) }
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width / CGFloat(subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * width, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}
