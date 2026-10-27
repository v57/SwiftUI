import Foundation

// MARK: - Search environment

/// Clears and deactivates the enclosing search (`@Environment(\.dismissSearch)`).
public struct DismissSearchAction: @unchecked Sendable {
    let action: @MainActor () -> Void
    @MainActor public func callAsFunction() { action() }
}

struct DismissSearchKey: EnvironmentKey { static let defaultValue = DismissSearchAction { } }
struct SearchSuggestionsKey: EnvironmentKey { static let defaultValue: AnyView? = nil }
struct SearchScopesKey: EnvironmentKey { static let defaultValue: AnyView? = nil }
struct TextInputSuggestionsKey: EnvironmentKey { static let defaultValue: AnyView? = nil }

extension EnvironmentValues {
    public var dismissSearch: DismissSearchAction {
        get { self[DismissSearchKey.self] }
        set { self[DismissSearchKey.self] = newValue }
    }
    var searchSuggestions: AnyView? {
        get { self[SearchSuggestionsKey.self] }
        set { self[SearchSuggestionsKey.self] = newValue }
    }
    var searchScopes: AnyView? {
        get { self[SearchScopesKey.self] }
        set { self[SearchScopesKey.self] = newValue }
    }
    var textInputSuggestions: AnyView? {
        get { self[TextInputSuggestionsKey.self] }
        set { self[TextInputSuggestionsKey.self] = newValue }
    }
}

extension ContainerValues {
    /// The text a suggestion row completes to (`searchCompletion` / `textInputCompletion`).
    @Entry var searchCompletion: String? = nil
}

public enum SearchPresentationToolbarBehavior: Hashable, Sendable { case automatic, avoidHidingContent }
public enum SearchToolbarBehavior: Hashable, Sendable { case automatic, minimize }
public struct SearchSuggestionsPlacement: Hashable, Sendable {
    let id: Int
    public static let automatic = SearchSuggestionsPlacement(id: 0)
    public static let content = SearchSuggestionsPlacement(id: 1)
    public static let menu = SearchSuggestionsPlacement(id: 2)
}
public struct SearchScopeActivation: Hashable, Sendable {
    public static let automatic = SearchScopeActivation()
    public static let onTextEntry = SearchScopeActivation()
    public static let onSearchPresentation = SearchScopeActivation()
}

extension View {
    /// Suggestions shown below the search field while searching; rows with `searchCompletion`
    /// fill the field when chosen.
    public func searchSuggestions<S: View>(@ViewBuilder _ suggestions: () -> S) -> some View {
        environment(\.searchSuggestions, AnyView(suggestions()))
    }

    public func searchSuggestions(_ visibility: Visibility, for placements: SearchSuggestionsPlacement...) -> some View {
        transformEnvironment(\.searchSuggestions) { if visibility == .hidden { $0 = nil } }
    }

    @_disfavoredOverload public func searchCompletion<S: StringProtocol>(_ completion: S) -> some View {
        containerValue(\.searchCompletion, String(completion))
    }

    public func searchCompletion(_ token: some Identifiable) -> some View { self }

    /// Scopes shown as a segmented control below the search field.
    public func searchScopes<V: Hashable, S: View>(_ scope: Binding<V>, @ViewBuilder scopes: () -> S) -> some View {
        environment(\.searchScopes, AnyView(Picker("Scope", selection: scope) { scopes() }.pickerStyle(.segmented).labelsHidden()))
    }

    public func searchScopes<V: Hashable, S: View>(_ scope: Binding<V>, activation: SearchScopeActivation, @ViewBuilder _ scopes: () -> S) -> some View {
        searchScopes(scope, scopes: scopes)
    }

    /// The search field's text selection (`TextSelection`); recorded only.
    public func searchSelection(_ selection: Binding<TextSelection?>) -> some View { self }
    /// Toolbar-collapsing search presentation is an iOS behavior.
    public func searchPresentationToolbarBehavior(_ behavior: SearchPresentationToolbarBehavior) -> some View { self }
    public func searchToolbarBehavior(_ behavior: SearchToolbarBehavior) -> some View { self }

    /// Suggestions under a text field while it is edited (`textInputCompletion` rows fill it).
    public func textInputSuggestions<S: View>(@ViewBuilder _ suggestions: () -> S) -> some View {
        environment(\.textInputSuggestions, AnyView(suggestions()))
    }

    public func textInputSuggestions<Data: RandomAccessCollection, Content: View>(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) -> some View where Data.Element: Identifiable {
        environment(\.textInputSuggestions, AnyView(ForEach(data, content: content)))
    }

    public func textInputSuggestions<Data: RandomAccessCollection, ID: Hashable, Content: View>(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) -> some View {
        environment(\.textInputSuggestions, AnyView(ForEach(data, id: id, content: content)))
    }

    @_disfavoredOverload public func textInputCompletion<S: StringProtocol>(_ completion: S) -> some View {
        containerValue(\.searchCompletion, String(completion))
    }
}

/// A text selection range (search field / text views).
public struct TextSelection: Hashable, Sendable {
    public var indices: Indices
    public var affinity: TextSelectionAffinity = .automatic
    public var isInsertion: Bool { if case .selection(let range) = indices { range.isEmpty } else { false } }

    public enum Indices: Hashable, Sendable {
        case selection(Range<String.Index>)
        /// Several ranges (multi-cursor selection).
        case multiSelection([Range<String.Index>])
    }

    public init(range: Range<String.Index>) { indices = .selection(range) }
    public init(insertionPoint: String.Index) { indices = .selection(insertionPoint..<insertionPoint) }
    @available(macOS 15.0, *)
    public init(ranges: RangeSet<String.Index>) { indices = .multiSelection(Array(ranges.ranges)) }
}

public enum TextSelectionAffinity: Hashable, Sendable { case automatic, upstream, downstream }

/// The selection of a `TextEditor` of an attributed string (`TextEditor(text:selection:)`): an insertion point or
/// ranges of the text's indices.
@available(macOS 15.0, iOS 18.0, *)
public struct AttributedTextSelection: Equatable, Sendable {
    public enum Indices: Equatable, Sendable {
        case insertionPoint(AttributedString.Index)
        case ranges(RangeSet<AttributedString.Index>)
    }

    /// Nil: the start of the text.
    var storage: Indices?

    /// An insertion point at the start of the text.
    public init() {}
    public init(insertionPoint: AttributedString.Index) { storage = .insertionPoint(insertionPoint) }
    public init(range: Range<AttributedString.Index>) {
        storage = range.isEmpty ? .insertionPoint(range.lowerBound) : .ranges(RangeSet(range))
    }
    public init(ranges: RangeSet<AttributedString.Index>) {
        if let first = ranges.ranges.first, ranges.ranges.count == 1, first.isEmpty {
            storage = .insertionPoint(first.lowerBound)
        } else {
            storage = ranges.ranges.isEmpty ? nil : .ranges(ranges)
        }
    }

    /// The selection's indices in `text` (the text it was made for).
    public func indices(in text: AttributedString) -> Indices { storage ?? .insertionPoint(text.startIndex) }

    /// The attributes at the selection's start, which typing would give new text.
    public func typingAttributes(in text: AttributedString) -> AttributeContainer {
        let index: AttributedString.Index
        switch indices(in: text) {
        case .insertionPoint(let point): index = point
        case .ranges(let ranges): index = ranges.ranges.first?.lowerBound ?? text.startIndex
        }
        guard !text.characters.isEmpty else { return AttributeContainer() }
        let at = index < text.endIndex ? index : text.characters.index(before: text.endIndex)
        return text[at..<text.characters.index(after: at)].runs.first?.attributes ?? AttributeContainer()
    }

    /// The selection as UTF-16 offsets into `text`'s characters (the first range of several).
    func utf16Range(in text: AttributedString) -> Range<Int> {
        let scalars = text.unicodeScalars
        func offset(_ index: AttributedString.Index) -> Int {
            let clamped = min(max(index, text.startIndex), text.endIndex)
            return scalars[text.startIndex..<clamped].reduce(0) { $0 + $1.utf16.count }
        }
        switch indices(in: text) {
        case .insertionPoint(let point):
            let at = offset(point)
            return at..<at
        case .ranges(let ranges):
            guard let first = ranges.ranges.first else { return 0..<0 }
            let lower = offset(first.lowerBound)
            return lower..<(lower + scalars[first].reduce(0) { $0 + $1.utf16.count })
        }
    }

    /// The selection of the UTF-16 offsets `range` in `text`'s characters.
    init(utf16 range: Range<Int>, in text: AttributedString) {
        let string = String(text.characters)
        let utf16 = string.utf16
        func index(_ offset: Int) -> AttributedString.Index {
            let stringIndex = utf16.index(utf16.startIndex, offsetBy: min(max(0, offset), utf16.count))
            // Rounded down to a scalar boundary (an offset inside a surrogate pair).
            let scalarIndex = stringIndex.samePosition(in: string.unicodeScalars) ?? string.unicodeScalars.index(before: stringIndex)
            let scalarCount = string.unicodeScalars.distance(from: string.unicodeScalars.startIndex, to: scalarIndex)
            return text.unicodeScalars.index(text.startIndex, offsetBy: scalarCount)
        }
        let lower = index(range.lowerBound)
        self.init(range: lower..<max(lower, index(range.upperBound)))
    }
}

extension View {
    /// Which side of a line break the caret prefers; recorded only (AppKit picks it).
    public func textSelectionAffinity(_ affinity: TextSelectionAffinity) -> some View { self }
}

// MARK: - Searchable container

/// Identifies one `searchable` so the list hosting its sidebar field can report that back.
@MainActor
final class SearchHostToken {}

/// A sidebar-placed search field waiting for a sidebar list to host it as its first row.
struct SidebarSearchField {
    let token: SearchHostToken
    let field: AnyView
}

struct SidebarSearchFieldKey: EnvironmentKey { static let defaultValue: SidebarSearchField? = nil }

extension EnvironmentValues {
    var sidebarSearchField: SidebarSearchField? {
        get { self[SidebarSearchFieldKey.self] }
        set { self[SidebarSearchFieldKey.self] = newValue }
    }
}

/// Where SwiftUI puts a `searchable` field on macOS (measured): `.sidebar` fields become the first
/// row of a sidebar-style list in the content; inside a split view's sidebar column the field
/// sits above the column's content; everywhere else it is the window toolbar's search field.
struct _Searchable<Content: View>: View {
    let content: Content
    let text: Binding<String>
    let isPresented: Binding<Bool>?
    let prompt: String
    var placement: SearchFieldPlacement = .automatic
    @FocusState private var isFieldFocused: Bool
    @State private var token = SearchHostToken()
    @Environment(\.searchSuggestions) private var suggestions
    @Environment(\.searchScopes) private var scopes
    @Environment(\.searchFocusRequest) private var externalFocus
    @Environment(\.isSidebarColumn) private var isSidebarColumn
    @Environment(\.self) private var environment

    var body: some View {
        let text = self.text
        let isActive = isFieldFocused || !text.wrappedValue.isEmpty || (isPresented?.wrappedValue ?? false)
        let focus = $isFieldFocused
        let isPresented = self.isPresented
        let field = _SearchField(prompt: prompt, text: text)
            .modifier(_OptionalFocus(binding: externalFocus == nil ? focus : nil))
            .modifier(_SuggestionsPopover(suggestions: suggestions, isEditing: isFieldFocused || !text.wrappedValue.isEmpty, text: text) { focus.wrappedValue = false })
        VStack(spacing: 0) {
            if isSidebarColumn {
                // Measured (macOS 26, split view sidebar): 9pt above, 12pt below, 10pt sides.
                field
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 12)
            }
            if let scopes, isActive {
                scopes.padding(.horizontal, 10).padding(.bottom, 8)
            }
            content
                .environment(\.isSearching, isActive)
                .environment(\.dismissSearch, DismissSearchAction {
                    text.wrappedValue = ""
                    focus.wrappedValue = false
                    isPresented?.wrappedValue = false
                })
                .transformEnvironment(\.sidebarSearchField) { hosted in
                    if !isSidebarColumn, placement == .sidebar { hosted = SidebarSearchField(token: token, field: AnyView(field)) }
                }
        }
        .transformPreference(ToolbarItemsKey.self) { [token, environment] items in
            guard !isSidebarColumn else { return }
            if let index = items.firstIndex(where: { $0.hostedSearch == ObjectIdentifier(token) }) {
                // A sidebar list shows the field.
                items.remove(at: index)
            } else {
                var entry = ToolbarEntry(
                    id: "search.\(ObjectIdentifier(token).hashValue)", placement: .primaryAction,
                    content: AnyView(field.environment(\._searchFieldInToolbar, true).frame(width: 324)), environment: environment, button: nil
                )
                entry.search = ToolbarSearchField(prompt: prompt, text: text.wrappedValue)
                items.append(entry)
            }
        }
        .onChange(of: isFieldFocused) { _, focused in
            if focused { isPresented?.wrappedValue = true }
        }
        .onChange(of: isPresented?.wrappedValue ?? false) { _, presented in
            if presented != isFieldFocused { isFieldFocused = presented }
        }
    }
}

/// The search field: magnifying glass, text, clear button. Classic design (macOS 15 and
/// earlier): a 28pt rounded bezel, white or (on sidebar material) translucent; modern design:
/// a filled capsule.
struct _SearchField: View {
    let prompt: String
    let text: Binding<String>
    @Environment(\._controlDesign) private var design
    @Environment(\._onSidebarMaterial) private var onSidebarMaterial
    @Environment(\._searchFieldInToolbar) private var inToolbar

    var body: some View {
        let text = self.text
        let modern = design == .modern
        // Classic fields draw their icons in the label color (measured), modern ones secondary.
        let iconStyle = modern ? HierarchicalShapeStyle.secondary : .primary
        HStack(spacing: modern ? 5 : 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(iconStyle)
            _SearchFieldInput(prompt: prompt, text: text)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(iconStyle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, modern ? 10 : 7)
        .padding(.trailing, modern ? 10 : 7.5)
        .frame(height: 28)
        .background {
            if modern {
                Capsule().fill(Color.searchFieldFill)
            } else if inToolbar {
                // Measured (classic, inactive window): a bezel over the toolbar background.
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.searchFieldBorder, lineWidth: 1).padding(0.5)
            } else if onSidebarMaterial {
                RoundedRectangle(cornerRadius: 6).fill(Color.sidebarSearchFill).padding(0.5)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.controlBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.searchFieldBorder, lineWidth: 0.5))
                    .padding(0.5)
            }
        }
    }
}

struct OnSidebarMaterialKey: EnvironmentKey { static let defaultValue = false }
struct SearchFieldInToolbarKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Content drawn over the sidebar material (classic sidebar lists).
    var _onSidebarMaterial: Bool {
        get { self[OnSidebarMaterialKey.self] }
        set { self[OnSidebarMaterialKey.self] = newValue }
    }
    var _searchFieldInToolbar: Bool {
        get { self[SearchFieldInToolbarKey.self] }
        set { self[SearchFieldInToolbarKey.self] = newValue }
    }
}

struct _OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}

/// Shows suggestions in a popover under the field while it is edited; choosing a row with a
/// completion fills the field. Dismissing the popover hides it until the text changes.
struct _SuggestionsPopover: ViewModifier {
    let suggestions: AnyView?
    let isEditing: Bool
    let text: Binding<String>
    let finish: @MainActor () -> Void
    @State private var dismissedText: String?

    func body(content: Content) -> some View {
        let text = self.text
        let finish = self.finish
        let dismissed = $dismissedText
        let shows = suggestions != nil && isEditing && dismissedText != text.wrappedValue
        content.popover(isPresented: Binding(get: { shows }, set: { if !$0 { dismissed.wrappedValue = text.wrappedValue } }), arrowEdge: .bottom) {
            if let suggestions {
                _SuggestionRows(suggestions: suggestions) { completion in
                    text.wrappedValue = completion
                    dismissed.wrappedValue = completion
                    finish()
                }
            }
        }
    }
}

/// Suggestion rows; rows with a completion fill the field when clicked.
struct _SuggestionRows: View {
    let suggestions: AnyView
    let complete: @MainActor (String) -> Void

    var body: some View {
        let complete = self.complete
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: suggestions) { rows in
                ForEach(rows) { row in
                    let completion = row.containerValues.searchCompletion
                    row
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if let completion { complete(completion) } }
                }
            }
        }
    }
}

// MARK: - Text input behavior

public struct WritingToolsBehavior: Hashable, Sendable {
    public enum _Kind: Hashable, Sendable { case automatic, complete, limited, disabled }
    public let _kind: _Kind
    public static let automatic = WritingToolsBehavior(_kind: .automatic)
    public static let complete = WritingToolsBehavior(_kind: .complete)
    public static let limited = WritingToolsBehavior(_kind: .limited)
    public static let disabled = WritingToolsBehavior(_kind: .disabled)
    public var isDisabled: Bool { _kind == .disabled }
}

public struct TextInputFormattingControlPlacement: Hashable, Sendable {
    public static let automatic = TextInputFormattingControlPlacement()
    public static let inputAssistant = TextInputFormattingControlPlacement()
    public static let contextMenu = TextInputFormattingControlPlacement()
    public static let all = TextInputFormattingControlPlacement()
}

struct AutocorrectionDisabledKey: EnvironmentKey { static let defaultValue = false }
struct TextContentTypeKey: EnvironmentKey { static let defaultValue: String? = nil }
struct WritingToolsBehaviorKey: EnvironmentKey { static let defaultValue = WritingToolsBehavior.automatic }
struct WritingToolsAffordanceKey: EnvironmentKey { static let defaultValue = Visibility.automatic }
struct FormattingControlVisibilityKey: EnvironmentKey { static let defaultValue = Visibility.automatic }

extension EnvironmentValues {
    public var autocorrectionDisabled: Bool {
        get { self[AutocorrectionDisabledKey.self] }
        set { self[AutocorrectionDisabledKey.self] = newValue }
    }
    public var _textContentType: String? {
        get { self[TextContentTypeKey.self] }
        set { self[TextContentTypeKey.self] = newValue }
    }
    public var writingToolsBehavior: WritingToolsBehavior {
        get { self[WritingToolsBehaviorKey.self] }
        set { self[WritingToolsBehaviorKey.self] = newValue }
    }
    var writingToolsAffordanceVisibility: Visibility {
        get { self[WritingToolsAffordanceKey.self] }
        set { self[WritingToolsAffordanceKey.self] = newValue }
    }
    var textInputFormattingControlVisibility: Visibility {
        get { self[FormattingControlVisibilityKey.self] }
        set { self[FormattingControlVisibilityKey.self] = newValue }
    }
}

extension View {
    /// Text fields and editors in the content don't autocorrect spelling.
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { environment(\.autocorrectionDisabled, disable) }
    /// An autofill content type for platforms whose types aren't `NSTextContentType`.
    public func textContentType<T>(_ type: T?) -> some View {
        environment(\._textContentType, type.flatMap { ($0 as? any RawRepresentable)?.rawValue as? String })
    }
    /// How Writing Tools may change text in editors (macOS 15+).
    public func writingToolsBehavior(_ behavior: WritingToolsBehavior) -> some View { environment(\.writingToolsBehavior, behavior) }
    public func writingToolsAffordanceVisibility(_ visibility: Visibility) -> some View { environment(\.writingToolsAffordanceVisibility, visibility) }
    /// Shows the text-formatting controls of rich-text editors.
    public func textInputFormattingControlVisibility(_ visibility: Visibility, for placement: TextInputFormattingControlPlacement) -> some View {
        environment(\.textInputFormattingControlVisibility, visibility)
    }
}
