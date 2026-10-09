import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreTransferable)
import CoreTransferable
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Table: header, sortable columns, explicit rows (TableRow with drag & drop), selection, context
// menus. Metrics measured on macOS 26 SwiftUI (inset style): 28pt header (11pt semibold titles), rows from 5pt below it,
// 24pt minimum row height, 10pt content inset, alternating rounded stripes (odd rows), first column
// text inset 6pt, others 8.5pt.

// MARK: - Columns

@MainActor
public struct TableColumn<RowValue> {
    let title: Text
    var width: (min: CGFloat?, ideal: CGFloat?, max: CGFloat?, fixed: CGFloat?) = (nil, nil, nil, nil)
    let content: @MainActor (RowValue) -> AnyView
    /// The column's sort comparator (a `SortComparator` whose `Compared == RowValue`).
    let comparator: (any Hashable)?

    init(title: Text, comparator: (any Hashable)?, content: @escaping @MainActor (RowValue) -> AnyView) {
        self.title = title
        self.comparator = comparator
        self.content = content
    }

    public init<S: StringProtocol, C: View>(_ title: S, @ViewBuilder content: @escaping (RowValue) -> C) {
        self.init(title: Text(title), comparator: nil, content: { AnyView(content($0)) })
    }

    public init<C: View>(_ title: Text, @ViewBuilder content: @escaping (RowValue) -> C) {
        self.init(title: title, comparator: nil, content: { AnyView(content($0)) })
    }

    public init<S: StringProtocol>(_ title: S, value: KeyPath<RowValue, String> & Sendable) {
        self.init(title: Text(title), comparator: KeyPathComparator(value), content: { AnyView(Text($0[keyPath: value])) })
    }

    public init<S: StringProtocol, V: Comparable, C: View>(_ title: S, value: KeyPath<RowValue, V> & Sendable, @ViewBuilder content: @escaping (RowValue) -> C) {
        self.init(title: Text(title), comparator: KeyPathComparator(value), content: { AnyView(content($0)) })
    }

    public init<S: StringProtocol, V, Comparator: SortComparator, C: View>(_ title: S, value: KeyPath<RowValue, V> & Sendable, comparator: Comparator, @ViewBuilder content: @escaping (RowValue) -> C) where Comparator.Compared == V {
        self.init(title: Text(title), comparator: KeyPathComparator(value, comparator: comparator), content: { AnyView(content($0)) })
    }

    public init<S: StringProtocol, Comparator: SortComparator, C: View>(_ title: S, sortUsing comparator: Comparator, @ViewBuilder content: @escaping (RowValue) -> C) where Comparator.Compared == RowValue {
        self.init(title: Text(title), comparator: comparator, content: { AnyView(content($0)) })
    }

    public func width(_ width: CGFloat? = nil) -> TableColumn {
        var copy = self
        copy.width.fixed = width
        return copy
    }

    public func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> TableColumn {
        var copy = self
        copy.width = (min, ideal, max, nil)
        return copy
    }

    public func defaultVisibility(_ visibility: Visibility) -> TableColumn { self }
    public func customizationID(_ id: String) -> TableColumn { self }
    public func alignment(_ alignment: TextAlignment) -> TableColumn { self }
}

/// Columns generated from data (`TableColumnForEach`).
@MainActor
public struct TableColumnForEach<RowValue> {
    let columns: [TableColumn<RowValue>]

    public init<Data: RandomAccessCollection, ID: Hashable>(_ data: Data, id: KeyPath<Data.Element, ID>, @TableColumnBuilder<RowValue> content: (Data.Element) -> [TableColumn<RowValue>]) {
        var result: [TableColumn<RowValue>] = []
        for element in data { result.append(contentsOf: content(element)) }
        columns = result
    }

    public init<Data: RandomAccessCollection>(_ data: Data, @TableColumnBuilder<RowValue> content: (Data.Element) -> [TableColumn<RowValue>]) where Data.Element: Identifiable {
        var result: [TableColumn<RowValue>] = []
        for element in data { result.append(contentsOf: content(element)) }
        columns = result
    }
}

@resultBuilder @MainActor
public enum TableColumnBuilder<RowValue> {
    public static func buildExpression(_ column: TableColumn<RowValue>) -> [TableColumn<RowValue>] { [column] }
    public static func buildExpression(_ columns: TableColumnForEach<RowValue>) -> [TableColumn<RowValue>] { columns.columns }
    public static func buildBlock(_ columns: [TableColumn<RowValue>]...) -> [TableColumn<RowValue>] { columns.flatMap { $0 } }
    public static func buildOptional(_ columns: [TableColumn<RowValue>]?) -> [TableColumn<RowValue>] { columns ?? [] }
    public static func buildEither(first columns: [TableColumn<RowValue>]) -> [TableColumn<RowValue>] { columns }
    public static func buildEither(second columns: [TableColumn<RowValue>]) -> [TableColumn<RowValue>] { columns }
    public static func buildLimitedAvailability(_ columns: [TableColumn<RowValue>]) -> [TableColumn<RowValue>] { columns }
    public static func buildArray(_ columns: [[TableColumn<RowValue>]]) -> [TableColumn<RowValue>] { columns.flatMap { $0 } }
}

// MARK: - Rows

/// One row with its interactions.
@MainActor
public struct TableRowEntry<Value> {
    let value: Value
    var dragItem: (@MainActor () -> AnyObject?)?
    var drop: (types: [String], handler: any _DropHandler)?
    var contextMenu: AnyView?
}

@MainActor @preconcurrency
public protocol TableRowContent {
    associatedtype TableRowValue: Identifiable
    func _tableRows(into rows: inout [TableRowEntry<TableRowValue>])
}

public struct TableRow<Value: Identifiable>: TableRowContent {
    var entry: TableRowEntry<Value>

    public init(_ value: Value) { entry = TableRowEntry(value: value) }

    public func _tableRows(into rows: inout [TableRowEntry<Value>]) { rows.append(entry) }

    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> TableRow {
        var copy = self
        copy.entry.contextMenu = AnyView(menuItems())
        return copy
    }

    public func itemProvider(_ action: (@MainActor () -> NSItemProvider?)?) -> TableRow {
        var copy = self
        if let action {
            copy.entry.dragItem = { () -> AnyObject? in action() }
        } else {
            copy.entry.dragItem = nil
        }
        return copy
    }
}

#if canImport(CoreTransferable)
extension TableRow {
    public func draggable<T: Transferable>(_ payload: @autoclosure @escaping () -> T) -> TableRow {
        var copy = self
        copy.entry.dragItem = {
            let provider = NSItemProvider()
            let value = UncheckedSendable(payload())
            provider.register(value.value)
            return provider
        }
        return copy
    }

    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping @MainActor ([T]) -> Void) -> TableRow {
        var copy = self
        let types = [UTType.fileURL, .url, .utf8PlainText, .plainText, .data, .image, .item].map(\.identifier)
        copy.entry.drop = (types, TransferableDropHandler<T>(action: { items, _ in action(items); return true }, isTargeted: { _ in }))
        return copy
    }
}
#endif

public struct _TupleTableRowContent<Value: Identifiable>: TableRowContent {
    let parts: [@MainActor (inout [TableRowEntry<Value>]) -> Void]
    public func _tableRows(into rows: inout [TableRowEntry<Value>]) { for part in parts { part(&rows) } }
}

public struct _EmptyTableRowContent<Value: Identifiable>: TableRowContent {
    public func _tableRows(into rows: inout [TableRowEntry<Value>]) {}
}

extension Optional: TableRowContent where Wrapped: TableRowContent {
    public typealias TableRowValue = Wrapped.TableRowValue
    public func _tableRows(into rows: inout [TableRowEntry<Wrapped.TableRowValue>]) { self?._tableRows(into: &rows) }
}

extension _ConditionalContent: TableRowContent where TrueContent: TableRowContent, FalseContent: TableRowContent, TrueContent.TableRowValue == FalseContent.TableRowValue {
    public typealias TableRowValue = TrueContent.TableRowValue
    public func _tableRows(into rows: inout [TableRowEntry<TrueContent.TableRowValue>]) {
        switch storage {
        case .trueContent(let content): content._tableRows(into: &rows)
        case .falseContent(let content): content._tableRows(into: &rows)
        }
    }
}

extension ForEach: TableRowContent where Content: TableRowContent {
    public typealias TableRowValue = Content.TableRowValue
    public func _tableRows(into rows: inout [TableRowEntry<Content.TableRowValue>]) {
        for element in data { content(element)._tableRows(into: &rows) }
    }
}

extension ForEach where Content: TableRowContent {
    public init(_ data: Data, @TableRowBuilder<Content.TableRowValue> content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {
        self.data = data
        self.content = content
        self.identify = { $0.id }
    }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @TableRowBuilder<Content.TableRowValue> content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identify = { $0[keyPath: id] }
    }
}

@resultBuilder @MainActor
public enum TableRowBuilder<Value: Identifiable> {
    public static func buildExpression<C: TableRowContent>(_ content: C) -> C where C.TableRowValue == Value { content }
    public static func buildBlock() -> _EmptyTableRowContent<Value> { _EmptyTableRowContent() }
    public static func buildBlock<C: TableRowContent>(_ content: C) -> C where C.TableRowValue == Value { content }
    public static func buildBlock<each C: TableRowContent>(_ content: repeat each C) -> _TupleTableRowContent<Value> {
        var parts: [@MainActor (inout [TableRowEntry<Value>]) -> Void] = []
        repeat parts.append(Self.part(each content))
        return _TupleTableRowContent(parts: parts)
    }
    private static func part<C: TableRowContent>(_ content: C) -> @MainActor (inout [TableRowEntry<Value>]) -> Void {
        { rows in
            var typed: [TableRowEntry<C.TableRowValue>] = []
            content._tableRows(into: &typed)
            rows.append(contentsOf: typed.compactMap { $0 as? TableRowEntry<Value> })
        }
    }
    public static func buildOptional<C: TableRowContent>(_ content: C?) -> C? { content }
    public static func buildEither<T: TableRowContent, F: TableRowContent>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .trueContent(first)) }
    public static func buildEither<T: TableRowContent, F: TableRowContent>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent(storage: .falseContent(second)) }
}

// MARK: - Styles and modifiers

public protocol TableStyle {}
public struct InsetTableStyle: TableStyle { public init() {} }
public struct BorderedTableStyle: TableStyle { public init() {} }
public struct AutomaticTableStyle: TableStyle { public init() {} }
extension TableStyle where Self == InsetTableStyle { public static var inset: InsetTableStyle { .init() } }
extension TableStyle where Self == BorderedTableStyle { public static var bordered: BorderedTableStyle { .init() } }
extension TableStyle where Self == AutomaticTableStyle { public static var automatic: AutomaticTableStyle { .init() } }

public enum AlternatingRowBackgroundBehavior: Sendable { case automatic, enabled, disabled }

struct TableBorderedKey: EnvironmentKey { static let defaultValue = false }
struct TableHeadersKey: EnvironmentKey { static let defaultValue = Visibility.automatic }
struct TableStripesKey: EnvironmentKey { static let defaultValue = AlternatingRowBackgroundBehavior.automatic }
struct SelectionMenuKey: EnvironmentKey { static let defaultValue: SelectionMenu? = nil }

/// `.contextMenu(forSelectionType:menu:primaryAction:)` for tables and lists.
@MainActor
struct SelectionMenu {
    let menu: @MainActor ([AnyHashable]) -> AnyView
    let primaryAction: (@MainActor ([AnyHashable]) -> Void)?
}

extension SelectionMenu: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: SelectionMenu, _ rhs: SelectionMenu) -> Bool { false }
}

extension EnvironmentValues {
    var tableIsBordered: Bool {
        get { self[TableBorderedKey.self] }
        set { self[TableBorderedKey.self] = newValue }
    }
    var tableHeaders: Visibility {
        get { self[TableHeadersKey.self] }
        set { self[TableHeadersKey.self] = newValue }
    }
    var tableStripes: AlternatingRowBackgroundBehavior {
        get { self[TableStripesKey.self] }
        set { self[TableStripesKey.self] = newValue }
    }
    var selectionMenu: SelectionMenu? {
        get { self[SelectionMenuKey.self] }
        set { self[SelectionMenuKey.self] = newValue }
    }
}

extension View {
    public func tableStyle<S: TableStyle>(_ style: S) -> some View {
        environment(\.tableIsBordered, style is BorderedTableStyle)
    }

    public func tableColumnHeaders(_ visibility: Visibility) -> some View {
        environment(\.tableHeaders, visibility)
    }

    public func alternatingRowBackgrounds(_ behavior: AlternatingRowBackgroundBehavior = .enabled) -> some View {
        environment(\.tableStripes, behavior)
    }

    public func contextMenu<I: Hashable, M: View>(forSelectionType itemType: I.Type = I.self, @ViewBuilder menu: @escaping (Set<I>) -> M, primaryAction: ((Set<I>) -> Void)? = nil) -> some View {
        func typed(_ values: [AnyHashable]) -> Set<I> { Set(values.compactMap { $0.base as? I }) }
        var primary: (@MainActor ([AnyHashable]) -> Void)?
        if let primaryAction {
            primary = { values in primaryAction(typed(values)) }
        }
        let selectionMenu = SelectionMenu(menu: { values in AnyView(menu(typed(values))) }, primaryAction: primary)
        return environment(\.selectionMenu, selectionMenu)
    }
}

// MARK: - Table

public struct Table<Value: Identifiable>: View {
    let rows: [TableRowEntry<Value>]
    let columns: [TableColumn<Value>]
    let selection: SelectionContext?
    let sort: TableSortState?
    @Environment(\.tableIsBordered) private var isBordered
    @Environment(\.tableHeaders) private var headers
    @Environment(\.tableStripes) private var stripes
    @Environment(\.selectionMenu) private var selectionMenu

    init(rows: [TableRowEntry<Value>], columns: [TableColumn<Value>], selection: SelectionContext?, sort: TableSortState?) {
        self.rows = rows
        self.columns = columns
        self.selection = selection
        self.sort = sort
    }

    static func entries<C: Collection>(_ data: C) -> [TableRowEntry<Value>] where C.Element == Value {
        data.map { TableRowEntry(value: $0) }
    }

    static func entries<R: TableRowContent>(_ content: R) -> [TableRowEntry<Value>] where R.TableRowValue == Value {
        var result: [TableRowEntry<Value>] = []
        content._tableRows(into: &result)
        return result
    }

    private var layout: _TableColumnsLayout { _TableColumnsLayout(columns: columns.map { _TableColumnSpec(width: $0.width) }) }
    private var contentInset: CGFloat { isBordered ? 1 : 10 }
    private var showsStripes: Bool { stripes != .disabled }

    public var body: some View {
        VStack(spacing: 0) {
            if headers != .hidden {
                header
                Rectangle().fill(Color.separator).frame(height: 1)
            }
            ScrollView {
                rowStack
                    .padding(.horizontal, contentInset)
                    .padding(.top, isBordered ? 0 : 5)
                    .background(alignment: .topLeading) { filler }
            }
        }
        .background(Color.controlBackground)
        .overlay { border }
    }

    private var header: some View {
        layout {
            ForEach(columns.indices, id: \.self) { index in headerCell(index) }
        }
        .padding(.horizontal, contentInset)
        .frame(height: 27)
    }

    private func headerCell(_ index: Int) -> _TableHeaderCell {
        let column = columns[index]
        var action: (@MainActor () -> Void)?
        if let comparator = column.comparator, let sort {
            action = { sort.sort(comparator) }
        }
        return _TableHeaderCell(title: column.title, isFirst: index == 0, isLast: index == columns.count - 1, direction: sort?.direction(column.comparator), sort: action)
    }

    private var rowStack: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.value.id) { offset, entry in
                row(offset: offset, entry: entry)
            }
        }
    }

    private func row(offset: Int, entry: TableRowEntry<Value>) -> some View {
        _TableRowView(
            cells: cells(for: entry.value),
            id: AnyHashable(entry.value.id),
            isStriped: showsStripes && offset % 2 == 1,
            isBordered: isBordered,
            selection: selection,
            selectionMenu: selectionMenu,
            entry: entry
        )
    }

    private func cells(for value: Value) -> some View {
        layout {
            ForEach(columns.indices, id: \.self) { index in cell(index, value) }
        }
    }

    private func cell(_ index: Int, _ value: Value) -> some View {
        let leading: CGFloat = index == 0 ? 6 : 8.5
        let trailing: CGFloat = index == columns.count - 1 ? 6 : 8.5
        return columns[index].content(value)
            .lineLimit(1)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var filler: some View {
        if showsStripes {
            _TableFillerStripes(startIndex: rows.count, top: isBordered ? 0 : 5, inset: contentInset, isBordered: isBordered)
        }
    }

    @ViewBuilder private var border: some View {
        if isBordered { Rectangle().strokeBorder(Color.listBorder, lineWidth: 1) }
    }
}

extension Table {
    public init<C: RandomAccessCollection>(_ data: C, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: nil, sort: nil)
    }

    public init<C: RandomAccessCollection>(_ data: C, selection: Binding<Value.ID?>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: .optional(selection), sort: nil)
    }

    public init<C: RandomAccessCollection>(_ data: C, selection: Binding<Set<Value.ID>>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: .multiple(selection), sort: nil)
    }

    public init<C: RandomAccessCollection, S: SortComparator>(_ data: C, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value, S.Compared == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: nil, sort: TableSortState(sortOrder))
    }

    public init<C: RandomAccessCollection, S: SortComparator>(_ data: C, selection: Binding<Value.ID?>, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value, S.Compared == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: .optional(selection), sort: TableSortState(sortOrder))
    }

    public init<C: RandomAccessCollection, S: SortComparator>(_ data: C, selection: Binding<Set<Value.ID>>, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>]) where C.Element == Value, S.Compared == Value {
        self.init(rows: Self.entries(data), columns: columns(), selection: .multiple(selection), sort: TableSortState(sortOrder))
    }

    public init<R: TableRowContent>(of valueType: Value.Type, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: nil, sort: nil)
    }

    public init<R: TableRowContent>(of valueType: Value.Type, selection: Binding<Value.ID?>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: .optional(selection), sort: nil)
    }

    public init<R: TableRowContent>(of valueType: Value.Type, selection: Binding<Set<Value.ID>>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: .multiple(selection), sort: nil)
    }

    public init<R: TableRowContent, S: SortComparator>(of valueType: Value.Type, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value, S.Compared == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: nil, sort: TableSortState(sortOrder))
    }

    public init<R: TableRowContent, S: SortComparator>(of valueType: Value.Type, selection: Binding<Value.ID?>, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value, S.Compared == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: .optional(selection), sort: TableSortState(sortOrder))
    }

    public init<R: TableRowContent, S: SortComparator>(of valueType: Value.Type, selection: Binding<Set<Value.ID>>, sortOrder: Binding<[S]>, @TableColumnBuilder<Value> columns: () -> [TableColumn<Value>], @TableRowBuilder<Value> rows: () -> R) where R.TableRowValue == Value, S.Compared == Value {
        self.init(rows: Self.entries(rows()), columns: columns(), selection: .multiple(selection), sort: TableSortState(sortOrder))
    }
}

/// The table's sort order binding, type-erased.
@MainActor
struct TableSortState {
    let direction: @MainActor ((any Hashable)?) -> SortOrder?
    let sort: @MainActor (any Hashable) -> Void

    init<S: SortComparator>(_ binding: Binding<[S]>) {
        func normalized(_ comparator: S) -> S {
            var copy = comparator
            copy.order = .forward
            return copy
        }
        direction = { column in
            guard let column = column as? S, let first = binding.wrappedValue.first, normalized(first) == normalized(column) else { return nil }
            return first.order
        }
        sort = { column in
            guard let column = column as? S else { return }
            var order = binding.wrappedValue
            if let first = order.first, normalized(first) == normalized(column) {
                // Clicking the sorted column flips its direction.
                order[0].order = first.order == .forward ? .reverse : .forward
            } else {
                order.removeAll { normalized($0) == normalized(column) }
                order.insert(normalized(column), at: 0)
            }
            binding.wrappedValue = order
        }
    }
}

struct _TableHeaderCell: View {
    let title: Text
    let isFirst: Bool
    let isLast: Bool
    let direction: SortOrder?
    let sort: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            title.font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.headerText).lineLimit(1)
            Spacer(minLength: 0)
            if let direction {
                Image(systemName: direction == .forward ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, (isFirst ? 6 : 8.5) + 2.5)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.separator).frame(width: 1, height: 16)
        }
        .contentShape(Rectangle())
        .onTapGesture { sort?() }
    }
}

struct _TableRowView<Cells: View, Value>: View {
    let cells: Cells
    let id: AnyHashable
    let isStriped: Bool
    let isBordered: Bool
    let selection: SelectionContext?
    let selectionMenu: SelectionMenu?
    let entry: TableRowEntry<Value>

    var body: some View {
        cells
            .padding(.vertical, 4)
            .frame(minHeight: 24)
            .background { background }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selectionMenu?.primaryAction?(selectedValues(including: id))
            }
            .onTapGesture { selection?.select(id) }
            .modifier(_TableRowMenu(menu: entry.contextMenu ?? selectionMenu.map { $0.menu(selectedValues(including: id)) }))
            .modifier(_TableRowDrag(makeItem: entry.dragItem))
            .modifier(_TableRowDrop(drop: entry.drop))
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: isBordered ? 0 : 6)
        if selection?.isSelected(id) ?? false {
            shape.fill(Color.listSelection)
        } else if isStriped {
            shape.fill(Color.tableStripe)
        }
    }

    /// The rows a menu or primary action applies to: the selection when it contains this row,
    /// otherwise just this row.
    private func selectedValues(including id: AnyHashable) -> [AnyHashable] {
        guard let selection else { return [id] }
        let current = selection.current()
        return current.contains(id) ? current : [id]
    }
}

struct _TableRowMenu: ViewModifier {
    let menu: AnyView?
    func body(content: Content) -> some View {
        if let menu { content.contextMenu { menu } } else { content }
    }
}

struct _TableRowDrag: ViewModifier {
    let makeItem: (@MainActor () -> AnyObject?)?
    func body(content: Content) -> some View {
        if let makeItem { content.modifier(_DragModifier(makeItem: makeItem)) } else { content }
    }
}

struct _TableRowDrop: ViewModifier {
    let drop: (types: [String], handler: any _DropHandler)?
    func body(content: Content) -> some View {
        if let drop { content.modifier(_DropModifier(types: drop.types, isTargeted: nil, delegate: drop.handler)) } else { content }
    }
}

/// Stripes continuing below the last row (24pt rows, like NSTableView's empty rows).
struct _TableFillerStripes: View {
    let startIndex: Int
    let top: CGFloat
    let inset: CGFloat
    let isBordered: Bool

    var body: some View {
        GeometryReader { proxy in
            let count = max(0, Int((proxy.size.height + 2000) / 24))
            ForEach(0..<count, id: \.self) { offset in
                let index = startIndex + offset
                if index % 2 == 1 {
                    RoundedRectangle(cornerRadius: isBordered ? 0 : 6)
                        .fill(Color.tableStripe)
                        .frame(width: max(0, proxy.size.width - 2 * inset), height: 24)
                        .offset(x: inset, y: top + CGFloat(index) * 24)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Column layout

struct _TableColumnSpec: Equatable {
    var min: CGFloat?
    var ideal: CGFloat?
    var max: CGFloat?
    var fixed: CGFloat?

    init(width: (min: CGFloat?, ideal: CGFloat?, max: CGFloat?, fixed: CGFloat?)) {
        min = width.min
        ideal = width.ideal
        max = width.max
        fixed = width.fixed
    }
}

/// Places one view per column; columns share the width like NSTableView (fixed widths first,
/// the rest split between flexible columns within their min/max). Each slot includes the cell
/// insets (6pt at the outer edges, 8.5pt between columns).
struct _TableColumnsLayout: Layout, Equatable {
    let columns: [_TableColumnSpec]

    private func inset(_ index: Int) -> CGFloat {
        (index == 0 ? 6 : 8.5) + (index == columns.count - 1 ? 6 : 8.5)
    }

    func slots(for width: CGFloat?) -> [CGFloat] {
        var widths = columns.map { $0.fixed ?? $0.ideal ?? 100 }
        guard let width else { return widths.indices.map { widths[$0] + inset($0) } }
        let insets = columns.indices.reduce(CGFloat(0)) { $0 + inset($1) }
        let flexible = columns.indices.filter { columns[$0].fixed == nil }
        let fixedTotal = columns.indices.filter { columns[$0].fixed != nil }.reduce(CGFloat(0)) { $0 + widths[$1] }
        var remaining = max(0, width - insets - fixedTotal)
        var open = flexible
        // Distribute, clamping to min/max, until stable.
        for _ in 0..<4 where !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            var next: [Int] = []
            for index in open {
                let spec = columns[index]
                let clamped = Swift.min(spec.max ?? .greatestFiniteMagnitude, Swift.max(spec.min ?? 0, share))
                widths[index] = clamped
                if clamped == share { next.append(index) }
            }
            let used = open.filter { !next.contains($0) }.reduce(CGFloat(0)) { $0 + widths[$1] }
            remaining = max(0, remaining - used)
            if next.count == open.count { break }
            open = next
        }
        return widths.indices.map { widths[$0] + inset($0) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let slots = slots(for: proposal.width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < slots.count {
            height = Swift.max(height, subview.sizeThatFits(ProposedViewSize(width: slots[index], height: proposal.height)).height)
        }
        return CGSize(width: proposal.width ?? slots.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let slots = slots(for: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < slots.count {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: slots[index], height: bounds.height))
            x += slots[index]
        }
    }
}

extension Color {
    static let tableStripe = dynamic(rgb(0, 0, 0, 0.04), rgb(1, 1, 1, 0.047))
    static let headerText = dynamic(rgb(0, 0, 0, 0.85), rgb(1, 1, 1, 1))
}
