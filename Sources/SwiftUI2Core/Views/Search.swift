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

extension View {
    /// Which side of a line break the caret prefers; recorded only (AppKit picks it).
    public func textSelectionAffinity(_ affinity: TextSelectionAffinity) -> some View { self }
}

// MARK: - Searchable container

/// The search field above the content, with scopes and a suggestions dropdown.
struct _Searchable<Content: View>: View {
    let content: Content
    let text: Binding<String>
    let isPresented: Binding<Bool>?
    let prompt: String
    @FocusState private var isFieldFocused: Bool
    @Environment(\.searchSuggestions) private var suggestions
    @Environment(\.searchScopes) private var scopes
    @Environment(\.searchFocusRequest) private var externalFocus

    var body: some View {
        let text = self.text
        let isActive = isFieldFocused || !text.wrappedValue.isEmpty || (isPresented?.wrappedValue ?? false)
        let focus = $isFieldFocused
        let isPresented = self.isPresented
        VStack(spacing: 0) {
            // macOS 26 search field: a 28pt capsule above the content (measured in a sidebar).
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                _SearchFieldInput(prompt: prompt, text: text)
                    .modifier(_OptionalFocus(binding: externalFocus == nil ? focus : nil))
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.searchFieldFill))
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 12)
            .modifier(_SuggestionsPopover(suggestions: suggestions, isEditing: isFieldFocused || !text.wrappedValue.isEmpty, text: text) { focus.wrappedValue = false })
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
        }
        .onChange(of: isFieldFocused) { _, focused in
            if focused { isPresented?.wrappedValue = true }
        }
        .onChange(of: isPresented?.wrappedValue ?? false) { _, presented in
            if presented != isFieldFocused { isFieldFocused = presented }
        }
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
