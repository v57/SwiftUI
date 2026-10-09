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

    static func single<V: Hashable>(_ binding: Binding<V>) -> SelectionContext {
        SelectionContext(
            isSelected: { selectionMatches(AnyHashable(binding.wrappedValue), $0) },
            select: { tag in
                if let value = tag?.base as? V { binding.wrappedValue = value }
                else if let unwrapped = (tag?.base as Any?).flatMap({ $0 as? V }) { binding.wrappedValue = unwrapped }
            },
            id: nil
        )
    }

    static func optional<V: Hashable>(_ binding: Binding<V?>) -> SelectionContext {
        SelectionContext(
            isSelected: { tag in binding.wrappedValue.map { selectionMatches(AnyHashable($0), tag) } ?? false },
            select: { tag in binding.wrappedValue = tag?.base as? V },
            id: nil
        )
    }

    static func multiple<V: Hashable>(_ binding: Binding<Set<V>>) -> SelectionContext {
        SelectionContext(
            isSelected: { tag in (tag?.base as? V).map { binding.wrappedValue.contains($0) } ?? false },
            select: { tag in if let value = tag?.base as? V { binding.wrappedValue = [value] } },
            id: nil
        )
    }
}

// MARK: - List

public enum ListStyleKind: Hashable, Sendable { case automatic, plain, inset, insetGrouped, grouped, sidebar, bordered }

public protocol ListStyle {}
public struct DefaultListStyle: ListStyle { public init() {} }
public struct PlainListStyle: ListStyle { public init() {} }
public struct InsetListStyle: ListStyle { public init() {} }
public struct SidebarListStyle: ListStyle { public init() {} }
public struct BorderedListStyle: ListStyle { public init() {} }
extension ListStyle where Self == DefaultListStyle { public static var automatic: DefaultListStyle { .init() } }
extension ListStyle where Self == PlainListStyle { public static var plain: PlainListStyle { .init() } }
extension ListStyle where Self == InsetListStyle { public static var inset: InsetListStyle { .init() } }
extension ListStyle where Self == SidebarListStyle { public static var sidebar: SidebarListStyle { .init() } }
extension ListStyle where Self == BorderedListStyle { public static var bordered: BorderedListStyle { .init() } }

struct ListContextKey: EnvironmentKey { static let defaultValue: ListContext? = nil }

@MainActor
struct ListContext {
    let selection: SelectionContext?
    let isForm: Bool
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
}

extension View {
    public func listStyle<S: ListStyle>(_ style: S) -> some View { self }
    public func listRowInsets(_ insets: EdgeInsets?) -> some View { self }
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }
    public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }
    public func scrollContentBackground(_ visibility: Visibility) -> some View { self }
    public func formStyle<S: FormStyle>(_ style: S) -> some View { self }
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

public protocol FormStyle {}
public struct GroupedFormStyle: FormStyle { public init() {} }
public struct ColumnsFormStyle: FormStyle { public init() {} }
public struct AutomaticFormStyle: FormStyle { public init() {} }
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

    func body(content: Content) -> some View {
        content
            .padding(.vertical, isForm ? 6 : 4)
            .padding(.horizontal, isForm ? 0 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25))
                } else if let background {
                    background
                }
            }
            .modifier(_OptionalTap(action: select))
            .modifier(_OptionalDeleteMenu(delete: delete))
    }
}

struct _OptionalTap: ViewModifier {
    let action: (@MainActor () -> Void)?
    func body(content: Content) -> some View {
        if let action { content.onTapGesture(perform: action) } else { content }
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
        wrapped(in: subgraph) { traits, itemSubgraph in
            makeObservedAttribute(itemSubgraph, of: _ListRowModifier.self) {
                makeListRowModifier(traits: traits, environment: environment.value)
            }
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
    var delete: (@MainActor () -> Void)?
    if let action = traits.value(DeleteActionTraitKey.self), let index = traits.value(DeleteIndexTraitKey.self) {
        delete = { action(IndexSet(integer: index)) }
    }
    let isSelected = tag != nil && (selection?.isSelected(tag) ?? false)
    return _ListRowModifier(
        isSelected: isSelected,
        select: select,
        background: traits.value(ListRowBackgroundTraitKey.self),
        delete: delete,
        isForm: context?.isForm ?? false
    )
}

public struct List<SelectionValue: Hashable, Content: View>: View {
    let content: Content
    let selection: SelectionContext?

    public var body: some View {
        ScrollView {
            _ListRows(content: content)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environment(\.listContext, ListContext(selection: selection, isForm: false))
    }
}

/// Rows of a list (top-level rows get row chrome; sections apply their own).
struct _ListRows<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs).list
        let rows = list.listRows(in: inputs.subgraph, environment: inputs.environment)
        // Lists are lazy: only rows near the visible area are built.
        let leading = HorizontalAlignment.leading
        return inputs.makeLazyStack(axis: .vertical, crossGuide: (leading.key, leading.id), spacing: 2, list: rows, eagerLayout: inputs.constant(_VStackLayout(alignment: .leading, spacing: 2)))
    }
}

extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = nil
    }
}

extension List {
    public init(selection: Binding<SelectionValue?>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = .optional(selection)
    }

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = .single(selection)
    }

    public init(selection: Binding<Set<SelectionValue>>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = .multiple(selection)
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

    public func onMove(perform action: ((IndexSet, Int) -> Void)?) -> ForEach { self }
    public func onInsert(of types: [String], perform action: @escaping (Int, [Any]) -> Void) -> ForEach { self }
}

public struct _DeletableForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    let base: ForEach<Data, ID, Content>
    let action: (@MainActor (IndexSet) -> Void)?

    public var body: Never { primitiveBody(Self.self) }

    public func onMove(perform action: ((IndexSet, Int) -> Void)?) -> _DeletableForEach { self }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let base = ForEach<Data, ID, Content>._makeViewList(view: view.project(inputs) { $0.base }, inputs: inputs).list
        let action = Attribute<(@MainActor (IndexSet) -> Void)?>(inputs.subgraph) { view.attribute.value.action }
        let forEach = view.project(inputs) { $0.base }
        let list = base.mapElements(in: inputs.subgraph) { element in
            var copy = element
            copy.traits[DeleteActionTraitKey.self] = action
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .environment(\.listContext, ListContext(selection: nil, isForm: true))
    }
}

public struct Section<Parent: View, Content: View, Footer: View>: View {
    let header: Parent?
    let content: Content
    let footer: Footer?
    @Environment(\.listContext) private var listContext

    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let header {
                header.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, listContext?.isForm == true ? 4 : 8)
            }
            if listContext?.isForm == true {
                _FormRows(content: content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
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

/// Form rows: one per element with dividers between them.
struct _FormRows<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs).list
        let rows = list.wrapped(in: inputs.subgraph) { _, subgraph in
            Attribute<_FormRowModifier>(subgraph, value: _FormRowModifier())
        }
        return inputs.makeLayoutContainer(layout: inputs.constant(_VStackLayout(alignment: .leading, spacing: 0)), list: rows)
    }
}

struct _FormRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.separator).frame(height: 1) }
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
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.header = Text(title)
        self.content = content()
        self.footer = nil
    }

    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.header = Text(titleKey)
        self.content = content()
        self.footer = nil
    }

    public init<S: StringProtocol>(_ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
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

    public var body: some View {
        let context = SelectionContext.single(selection)
        HStack(alignment: style == .radioGroup || style == .inline ? .firstTextBaseline : .center, spacing: 8) {
            if !labelsHidden {
                label
                if isInForm { Spacer(minLength: 8) }
            }
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
                .buttonStyle(.bordered)
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
}

extension Picker where Label == Text {
    public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
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
        return VStack(spacing: 0) {
            _ListTransformView(content: content, transform: { list, inputs in
                list.wrapped(in: inputs.subgraph) { traits, subgraph in
                    makeObservedAttribute(subgraph, of: _TabItemModifier.self) {
                        let tag = traits.value(TagTraitKey.self)
                        return _TabItemModifier(label: traits.value(TabItemTraitKey.self), isSelected: context.isSelected(tag), select: { context.select(tag) }, adoptIfUnset: {
                            if selection == nil, binding.wrappedValue == nil, let tag { binding.wrappedValue = tag }
                        })
                    }
                }
            }, layout: AnyLayout(_HStackLayout(spacing: 4)))
            .padding(.vertical, 6)
            Divider()
            _ListTransformView(content: content, transform: { list, inputs in
                list.filtered(in: inputs.subgraph, selection: current)
            }, layout: AnyLayout(_ZStackLayout(alignment: .topLeading)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    func body(content: Content) -> some View {
        (label ?? AnyView(Text("Tab")))
            .labelStyle(TitleAndIconLabelStyle())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .onTapGesture(perform: select)
            .onAppear(perform: adoptIfUnset)
    }
}

/// iOS 18 style `Tab("Title", systemImage:, value:) { content }`.
public struct Tab<Value: Hashable, Content: View>: View {
    let title: String
    let systemImage: String?
    let value: Value
    let content: Content

    public init(_ title: String, systemImage: String, value: Value, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.content = content()
    }

    public var body: some View {
        content
            .tabItem { if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) } }
            .tag(value)
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

struct _LazyGridLayout: Layout {
    let items: [GridItem]
    let spacing: CGFloat
    let axis: Axis

    func tracks(available: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        let gaps = items.map { $0.spacing ?? 8 }
        var remaining = available - gaps.dropLast().reduce(0, +)
        var flexible: [Int] = []
        for (index, item) in items.enumerated() {
            switch item.size {
            case .fixed(let value):
                result.append(value)
                remaining -= value
            case .flexible:
                result.append(0)
                flexible.append(index)
            case .adaptive(let minimum, let maximum):
                let count = max(1, Int((remaining + (item.spacing ?? 8)) / (minimum + (item.spacing ?? 8))))
                let width = min(maximum, (remaining - CGFloat(count - 1) * (item.spacing ?? 8)) / CGFloat(count))
                return Array(repeating: max(minimum, width), count: count)
            }
        }
        if !flexible.isEmpty {
            let share = max(0, remaining / CGFloat(flexible.count))
            for index in flexible {
                if case let .flexible(minimum, maximum) = items[index].size {
                    result[index] = min(max(share, minimum), maximum)
                }
            }
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let available = proposal[axis.other] ?? CGFloat(items.count) * 80
        let columns = tracks(available: available.isFinite ? available : CGFloat(items.count) * 80)
        guard !columns.isEmpty else { return .zero }
        var main: CGFloat = 0
        var index = 0
        var lines = 0
        while index < subviews.count {
            var lineSize: CGFloat = 0
            for column in columns.indices where index < subviews.count {
                let size = subviews[index].sizeThatFits(ProposedViewSize(main: nil, cross: columns[column], axis: axis))
                lineSize = max(lineSize, size[axis])
                index += 1
            }
            main += lineSize
            lines += 1
        }
        main += spacing * CGFloat(max(lines - 1, 0))
        let cross = columns.reduce(0, +) + CGFloat(max(columns.count - 1, 0)) * (items.first?.spacing ?? 8)
        return CGSize(main: main, cross: cross, axis: axis)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let columns = tracks(available: bounds.size[axis.other])
        guard !columns.isEmpty else { return }
        var position = bounds.origin[axis]
        var index = 0
        while index < subviews.count {
            var lineSize: CGFloat = 0
            var crossPosition = bounds.origin[axis.other]
            let start = index
            var sizes: [CGSize] = []
            for column in columns.indices where index < subviews.count {
                let size = subviews[index].sizeThatFits(ProposedViewSize(main: nil, cross: columns[column], axis: axis))
                sizes.append(size)
                lineSize = max(lineSize, size[axis])
                index += 1
            }
            for (offset, size) in sizes.enumerated() {
                let column = offset
                let crossOffset = (columns[column] - size[axis.other]) / 2
                let mainOffset = (lineSize - size[axis]) / 2
                let point = axis == .vertical
                    ? CGPoint(x: crossPosition + crossOffset, y: position + mainOffset)
                    : CGPoint(x: position + mainOffset, y: crossPosition + crossOffset)
                subviews[start + offset].place(at: point, proposal: ProposedViewSize(main: size[axis], cross: columns[column], axis: axis))
                crossPosition += columns[column] + (items[min(column, items.count - 1)].spacing ?? 8)
            }
            position += lineSize + spacing
        }
    }
}

public struct LazyVGrid<Content: View>: View {
    let columns: [GridItem]
    let spacing: CGFloat?
    let content: Content

    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        _LazyGridLayout(items: columns, spacing: spacing ?? 8, axis: .vertical) { content }
    }
}

public struct LazyHGrid<Content: View>: View {
    let rows: [GridItem]
    let spacing: CGFloat?
    let content: Content

    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        _LazyGridLayout(items: rows, spacing: spacing ?? 8, axis: .horizontal) { content }
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt?.plainString ?? "Search", text: text).textFieldStyle(.plain)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
            .padding(8)
            self
        }
    }

    public func searchable<S: StringProtocol>(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: S) -> some View {
        searchable(text: text, placement: placement, prompt: Text(prompt))
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
