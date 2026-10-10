import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Row traits

public enum ListRowInsetsTraitKey: _ViewTraitKey {
    public static var defaultValue: EdgeInsets? { nil }
}

/// Row separator visibility and tint per edge.
public struct ListRowSeparatorConfiguration: Hashable, Sendable {
    public var topVisibility = Visibility.automatic
    public var bottomVisibility = Visibility.automatic
    public var topTint: Color?
    public var bottomTint: Color?
}

public enum ListRowSeparatorTraitKey: _ViewTraitKey {
    public static var defaultValue: ListRowSeparatorConfiguration { ListRowSeparatorConfiguration() }
}

public enum ListSectionSeparatorTraitKey: _ViewTraitKey {
    public static var defaultValue: ListRowSeparatorConfiguration { ListRowSeparatorConfiguration() }
}

public enum ListBadgeTraitKey: _ViewTraitKey {
    public static var defaultValue: Text? { nil }
}

public enum ListItemTintTraitKey: _ViewTraitKey {
    public static var defaultValue: Color? { nil }
}

public enum SelectionDisabledTraitKey: _ViewTraitKey {
    public static var defaultValue: Bool { false }
}

public enum DeleteDisabledTraitKey: _ViewTraitKey {
    public static var defaultValue: Bool { false }
}

public enum MoveDisabledTraitKey: _ViewTraitKey {
    public static var defaultValue: Bool { false }
}

public enum MoveActionTraitKey: _ViewTraitKey {
    public static var defaultValue: (@MainActor (IndexSet, Int) -> Void)? { nil }
}

/// Identifies the ForEach whose rows can be reordered among each other.
public enum MoveTokenTraitKey: _ViewTraitKey {
    public static var defaultValue: Int { 0 }
}

/// Swipe actions (macOS offers them in the row's context menu).
public enum SwipeActionsTraitKey: _ViewTraitKey {
    public static var defaultValue: [AnyView] { [] }
}

public enum SectionActionsTraitKey: _ViewTraitKey {
    public static var defaultValue: AnyView? { nil }
}

public enum TypeSelectEquivalentTraitKey: _ViewTraitKey {
    public static var defaultValue: String? { nil }
}

extension View {
    public func listRowInsets(_ insets: EdgeInsets?) -> some View {
        modifier(_TraitWritingModifier<ListRowInsetsTraitKey>(value: insets))
    }

    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        _transformTrait(ListRowSeparatorTraitKey.self) { configuration in
            if edges.contains(.top) { configuration.topVisibility = visibility }
            if edges.contains(.bottom) { configuration.bottomVisibility = visibility }
        }
    }

    public func listRowSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View {
        _transformTrait(ListRowSeparatorTraitKey.self) { configuration in
            if edges.contains(.top) { configuration.topTint = color }
            if edges.contains(.bottom) { configuration.bottomTint = color }
        }
    }

    public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        _transformTrait(ListSectionSeparatorTraitKey.self) { configuration in
            if edges.contains(.top) { configuration.topVisibility = visibility }
            if edges.contains(.bottom) { configuration.bottomVisibility = visibility }
        }
    }

    public func listSectionSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View {
        _transformTrait(ListSectionSeparatorTraitKey.self) { configuration in
            if edges.contains(.top) { configuration.topTint = color }
            if edges.contains(.bottom) { configuration.bottomTint = color }
        }
    }

    /// A count or label at the trailing edge of a list row (or a tab).
    public func badge(_ count: Int) -> some View {
        modifier(_TraitWritingModifier<ListBadgeTraitKey>(value: count == 0 ? nil : Text("\(count)")))
    }

    public func badge(_ label: Text?) -> some View {
        modifier(_TraitWritingModifier<ListBadgeTraitKey>(value: label))
    }

    @_disfavoredOverload public func badge<S: StringProtocol>(_ label: S?) -> some View {
        modifier(_TraitWritingModifier<ListBadgeTraitKey>(value: label.map { Text($0) }))
    }

    public func badge(_ key: LocalizedStringKey?) -> some View {
        modifier(_TraitWritingModifier<ListBadgeTraitKey>(value: key.map { Text($0) }))
    }

    /// Tints the row's icons (sidebar rows).
    public func listItemTint(_ tint: Color?) -> some View {
        modifier(_TraitWritingModifier<ListItemTintTraitKey>(value: tint))
    }

    public func listItemTint(_ tint: ListItemTint?) -> some View {
        modifier(_TraitWritingModifier<ListItemTintTraitKey>(value: tint?.color))
    }

    public func selectionDisabled(_ isDisabled: Bool = true) -> some View {
        modifier(_TraitWritingModifier<SelectionDisabledTraitKey>(value: isDisabled))
    }

    public func deleteDisabled(_ isDisabled: Bool) -> some View {
        modifier(_TraitWritingModifier<DeleteDisabledTraitKey>(value: isDisabled))
    }

    public func moveDisabled(_ isDisabled: Bool) -> some View {
        modifier(_TraitWritingModifier<MoveDisabledTraitKey>(value: isDisabled))
    }

    /// Swipe actions; on macOS they are offered in the row's context menu.
    public func swipeActions<T: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true, @ViewBuilder content: () -> T) -> some View {
        let view = AnyView(content())
        return _transformTrait(SwipeActionsTraitKey.self) { $0.append(view) }
    }

    /// Typing this text selects the row (List type-select).
    public func typeSelectEquivalent(_ text: Text?) -> some View {
        modifier(_TraitWritingModifier<TypeSelectEquivalentTraitKey>(value: text?.plainString))
    }

    @_disfavoredOverload public func typeSelectEquivalent<S: StringProtocol>(_ string: S) -> some View {
        modifier(_TraitWritingModifier<TypeSelectEquivalentTraitKey>(value: String(string)))
    }

    public func typeSelectEquivalent(_ key: LocalizedStringKey) -> some View {
        modifier(_TraitWritingModifier<TypeSelectEquivalentTraitKey>(value: key.key))
    }

    /// Actions shown at the trailing edge of a section's header (sidebars).
    public func sectionActions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        modifier(_TraitWritingModifier<SectionActionsTraitKey>(value: AnyView(content())))
    }

    func _transformTrait<Key: _ViewTraitKey>(_ key: Key.Type, _ transform: @escaping (inout Key.Value) -> Void) -> some View {
        modifier(_TraitTransformModifier<Key>(transform: transform))
    }
}

public struct ListItemTint: Sendable {
    let color: Color?
    public static func fixed(_ tint: Color) -> ListItemTint { ListItemTint(color: tint) }
    public static func preferred(_ tint: Color) -> ListItemTint { ListItemTint(color: tint) }
    public static let monochrome = ListItemTint(color: .secondary)
}

/// Transforms a trait (combining several modifiers writing the same key).
public struct _TraitTransformModifier<Key: _ViewTraitKey>: ViewModifier {
    let transform: (inout Key.Value) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        body(inputs)
    }

    public static func _makeViewList(modifier: _GraphValue<Self>, inputs: _ViewListInputs, body: @escaping @MainActor (_ViewListInputs) -> _ViewListOutputs) -> _ViewListOutputs {
        let content = body(inputs)
        let list = content.list.mapElements(in: inputs.subgraph) { element in
            var copy = element
            let previous = element.traits[Key.self]
            copy.traits[Key.self] = Attribute<Key.Value>(inputs.subgraph) {
                var value = previous?.value ?? Key.defaultValue
                modifier.attribute.value.transform(&value)
                return value
            }
            return copy
        }
        return _ViewListOutputs(list: list)
    }
}

// MARK: - List-wide settings

struct ListRowSpacingKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
struct ListSectionSpacingKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
struct HeaderProminenceKey: EnvironmentKey { static let defaultValue = Prominence.standard }
struct BadgeProminenceKey: EnvironmentKey { static let defaultValue = BadgeProminence.standard }
struct ScrollContentBackgroundKey: EnvironmentKey { static let defaultValue = Visibility.automatic }

extension EnvironmentValues {
    var listRowSpacing: CGFloat? {
        get { self[ListRowSpacingKey.self] }
        set { self[ListRowSpacingKey.self] = newValue }
    }
    var listSectionSpacing: CGFloat? {
        get { self[ListSectionSpacingKey.self] }
        set { self[ListSectionSpacingKey.self] = newValue }
    }
    public var headerProminence: Prominence {
        get { self[HeaderProminenceKey.self] }
        set { self[HeaderProminenceKey.self] = newValue }
    }
    public var badgeProminence: BadgeProminence {
        get { self[BadgeProminenceKey.self] }
        set { self[BadgeProminenceKey.self] = newValue }
    }
    var scrollContentBackground: Visibility {
        get { self[ScrollContentBackgroundKey.self] }
        set { self[ScrollContentBackgroundKey.self] = newValue }
    }
}

public enum ListSectionSpacing: Sendable {
    case `default`, compact
    case custom(CGFloat)
    var value: CGFloat? {
        switch self {
        case .default: nil
        case .compact: 8
        case .custom(let value): value
        }
    }
}

extension View {
    /// Extra space between rows.
    public func listRowSpacing(_ spacing: CGFloat?) -> some View { environment(\.listRowSpacing, spacing) }
    /// Space between sections.
    public func listSectionSpacing(_ spacing: CGFloat) -> some View { environment(\.listSectionSpacing, spacing) }
    public func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { environment(\.listSectionSpacing, spacing.value) }
    /// `.increased` draws section headers larger.
    public func headerProminence(_ prominence: Prominence) -> some View { environment(\.headerProminence, prominence) }
    public func badgeProminence(_ prominence: BadgeProminence) -> some View { environment(\.badgeProminence, prominence) }
    /// `.hidden` removes the list's (or form's) background.
    public func scrollContentBackground(_ visibility: Visibility) -> some View { environment(\.scrollContentBackground, visibility) }
}

// MARK: - Row chrome helpers

/// The badge at a row's trailing edge: a capsule count in sidebars, secondary text elsewhere.
struct _ListRowBadge: View {
    let badge: Text
    let isSidebar: Bool
    @Environment(\.badgeProminence) private var prominence

    var body: some View {
        if isSidebar {
            badge
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(prominence == .increased ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(prominence == .increased ? Color.red : Color.secondary.opacity(0.18)))
        } else {
            badge.foregroundStyle(prominence == .decreased ? Color.secondary.opacity(0.6) : Color.secondary).monospacedDigit()
        }
    }
}

/// Context menu of a row: swipe actions, then Delete.
struct _RowContextMenu: ViewModifier {
    let swipeActions: [AnyView]
    let delete: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        if swipeActions.isEmpty && delete == nil {
            content
        } else {
            content.contextMenu {
                ForEach(Array(swipeActions.enumerated()), id: \.offset) { $0.element }
                if let delete { Button("Delete", role: .destructive, action: delete) }
            }
        }
    }
}

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

/// Drag to reorder rows of a ForEach with `onMove`.
struct _RowReorder: ViewModifier {
    let token: Int
    let index: Int
    let move: @MainActor (IndexSet, Int) -> Void

    func body(content: Content) -> some View {
        let token = self.token
        let index = self.index
        let move = self.move
        content
            .onDrag { NSItemProvider(object: "swiftui2-row:\(token):\(index)" as NSString) }
            .onDrop(of: [.plainText, .utf8PlainText], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let string = object as? String else { return }
                    let parts = string.split(separator: ":")
                    guard parts.count == 3, parts[0] == "swiftui2-row", Int(parts[1]) == token, let source = Int(parts[2]), source != index else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            // SwiftUI's destination: the index the row is moved in front of.
                            move(IndexSet(integer: source), source < index ? index + 1 : index)
                        }
                    }
                }
                return true
            }
    }
}
#endif

// MARK: - Type select

/// Rows reachable by typing (their type-select text and selection tag).
@MainActor
final class TypeSelectRegistry {
    private var rows: [(owner: ObjectIdentifier, text: String, tag: AnyHashable)] = []
    private var typed = ""
    private var lastKey = Date.distantPast

    func set(owner: AnyObject, text: String?, tag: AnyHashable?) {
        let key = ObjectIdentifier(owner)
        rows.removeAll { $0.owner == key }
        if let text, let tag { rows.append((key, text, tag)) }
    }

    func remove(owner: AnyObject) { rows.removeAll { $0.owner == ObjectIdentifier(owner) } }

    /// The tag of the first row whose text starts with the typed prefix (typing pauses reset it).
    func match(_ characters: String, now: Date = Date()) -> AnyHashable? {
        if now.timeIntervalSince(lastKey) > 1 { typed = "" }
        lastKey = now
        typed += characters.lowercased()
        return rows.first { $0.text.lowercased().hasPrefix(typed) }?.tag
    }
}

struct TypeSelectRegistryKey: EnvironmentKey { static let defaultValue: TypeSelectRegistry? = nil }

extension EnvironmentValues {
    var typeSelectRegistry: TypeSelectRegistry? {
        get { self[TypeSelectRegistryKey.self] }
        set { self[TypeSelectRegistryKey.self] = newValue }
    }
}

extension TypeSelectRegistry: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: TypeSelectRegistry, _ rhs: TypeSelectRegistry) -> Bool { lhs === rhs }
}

/// Registers a row's type-select text while it exists.
struct _TypeSelectRow: ViewModifier {
    let text: String?
    let tag: AnyHashable?
    @Environment(\.typeSelectRegistry) private var registry
    @State private var owner = _FocusedValueOwner()

    func body(content: Content) -> some View {
        let registry = self.registry
        let owner = self.owner
        let text = self.text
        let tag = self.tag
        content
            .onAppear { registry?.set(owner: owner, text: text, tag: tag) }
            .onChange(of: TypeSelectEntry(text: text, tag: tag)) { _, entry in registry?.set(owner: owner, text: entry.text, tag: entry.tag) }
            .onDisappear { registry?.remove(owner: owner) }
    }

    struct TypeSelectEntry: Equatable {
        let text: String?
        let tag: AnyHashable?
    }
}
