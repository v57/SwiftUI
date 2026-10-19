import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Model

public struct AccessibilityTraits: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = AccessibilityTraits(rawValue: 1 << 1)
    public static let isSelected = AccessibilityTraits(rawValue: 1 << 2)
    public static let isLink = AccessibilityTraits(rawValue: 1 << 3)
    public static let isSearchField = AccessibilityTraits(rawValue: 1 << 4)
    public static let isImage = AccessibilityTraits(rawValue: 1 << 5)
    public static let playsSound = AccessibilityTraits(rawValue: 1 << 6)
    public static let isKeyboardKey = AccessibilityTraits(rawValue: 1 << 7)
    public static let isStaticText = AccessibilityTraits(rawValue: 1 << 8)
    public static let isSummaryElement = AccessibilityTraits(rawValue: 1 << 9)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 1 << 10)
    public static let startsMediaSession = AccessibilityTraits(rawValue: 1 << 11)
    public static let allowsDirectInteraction = AccessibilityTraits(rawValue: 1 << 12)
    public static let causesPageTurn = AccessibilityTraits(rawValue: 1 << 13)
    public static let isModal = AccessibilityTraits(rawValue: 1 << 14)
    public static let isToggle = AccessibilityTraits(rawValue: 1 << 15)
    public static let isTabBar = AccessibilityTraits(rawValue: 1 << 16)
}

public enum AccessibilityChildBehavior: Hashable, Sendable { case ignore, contain, combine }
public enum AccessibilityActionKind: Hashable, Sendable { case `default`, escape, magicTap, delete, showMenu }
public enum AccessibilityAdjustmentDirection: Hashable, Sendable { case increment, decrement }
public enum AccessibilityHeadingLevel: UInt, Hashable, Sendable { case unspecified, h1, h2, h3, h4, h5, h6 }
public enum AccessibilityZoomGestureActionDirection: Hashable, Sendable { case zoomIn, zoomOut }
public enum AccessibilityLabeledPairRole: Hashable, Sendable { case label, content }
public enum AccessibilityCustomContentImportance: Hashable, Sendable { case `default`, high }
public enum AccessibilityTextContentType: Hashable, Sendable { case plain, console, fileSystem, messaging, narrative, sourceCode, spreadsheet, wordProcessing }

public struct AccessibilityZoomGestureAction: Sendable {
    public let direction: AccessibilityZoomGestureActionDirection
    public let location: UnitPoint
    public let point: CGPoint
}

/// A custom-content line (`accessibilityCustomContent`).
public struct AccessibilityCustomContentEntry: Hashable, Sendable {
    public var label: String
    public var value: String
    public var isImportant: Bool
}

/// An accessibility action; `perform` reads the latest modifier value when invoked.
public struct AccessibilityActionHandler: Equatable, @unchecked Sendable {
    public enum Kind: Hashable, Sendable {
        case named(String)
        case standard(AccessibilityActionKind)
        case adjust(AccessibilityAdjustmentDirection)
        case scroll(Edge)
        case zoom(AccessibilityZoomGestureActionDirection)
    }
    public let kind: Kind
    public let perform: @MainActor () -> Void

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind }
}

/// What accessibility modifiers attach to the nearest platform view.
public struct AccessibilityProperties: Equatable, @unchecked Sendable {
    public var label: String?
    public var value: String?
    public var hint: String?
    public var identifier: String?
    public var isHidden = false
    public var addedTraits: AccessibilityTraits = []
    public var removedTraits: AccessibilityTraits = []
    public var sortPriority: Double = 0
    /// Set by `accessibilityElement(children:)`.
    public var children: AccessibilityChildBehavior?
    public var headingLevel: AccessibilityHeadingLevel?
    public var inputLabels: [String] = []
    public var actions: [AccessibilityActionHandler] = []
    public var respondsToUserInteraction: Bool?
    public var textContentType: AccessibilityTextContentType?
    public var customContent: [AccessibilityCustomContentEntry] = []
    public var activationPoint: UnitPoint?
    public var dragPoint: UnitPoint?
    public var dropPoint: UnitPoint?
    public var linkedGroup: AnyHashable?
    public var labeledPair: AnyHashable?
    public var isDefaultFocus = false

    public init() {}

    public var traits: AccessibilityTraits { addedTraits.subtracting(removedTraits) }
}


/// Properties waiting in the view inputs for the next platform node.
@MainActor
final class AccessibilityAttachment {
    let properties: Attribute<AccessibilityProperties>
    var isConsumed = false
    init(properties: Attribute<AccessibilityProperties>) { self.properties = properties }
}

// MARK: - Modifier

/// Edits the accessibility properties of the nearest platform view (or of the stack it is
/// applied to, which then becomes a group element).
public struct _AccessibilityModifier: ViewModifier {
    let edit: @MainActor (inout AccessibilityProperties, _ latest: @escaping @MainActor () -> _AccessibilityModifier) -> Void
    var _handlerBox: _HandlerBox?
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var inputs = inputs
        let parent = inputs.accessibility.flatMap { $0.isConsumed ? nil : $0.properties }
        let source = modifier.attribute
        let latest: @MainActor () -> _AccessibilityModifier = { [weak source] in
            AnyAttribute.withoutDependencies { source?.value ?? _AccessibilityModifier(edit: { _, _ in }, _handlerBox: nil) }
        }
        let properties = Attribute<AccessibilityProperties>(inputs.subgraph, isEqual: { $0 == $1 }) {
            var properties = parent?.value ?? AccessibilityProperties()
            source.value.edit(&properties, latest)
            return properties
        }
        inputs.accessibility = AccessibilityAttachment(properties: properties)
        return body(inputs)
    }
}

extension View {
    func _accessibility(_ edit: @escaping @MainActor (inout AccessibilityProperties) -> Void) -> some View {
        modifier(_AccessibilityModifier(edit: { properties, _ in edit(&properties) }, _handlerBox: nil))
    }

    /// An action whose handler is read from the latest modifier value when it runs.
    func _accessibilityAction(_ kind: AccessibilityActionHandler.Kind, handler: @escaping @MainActor () -> Void) -> some View {
        modifier(_AccessibilityModifier(edit: { properties, latest in
            properties.actions.removeAll { $0.kind == kind }
            properties.actions.append(AccessibilityActionHandler(kind: kind) { latest()._handler?() })
        }, handler: handler))
    }
}

extension _AccessibilityModifier {
    init(edit: @escaping @MainActor (inout AccessibilityProperties, _ latest: @escaping @MainActor () -> _AccessibilityModifier) -> Void, handler: @escaping @MainActor () -> Void) {
        self.edit = edit
        self._handlerBox = _HandlerBox(handler)
    }

    var _handler: (@MainActor () -> Void)? { _handlerBox?.handler }
}

final class _HandlerBox: @unchecked Sendable {
    let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
}

// MARK: - Labels, values, traits

extension View {
    public func accessibilityLabel(_ label: Text) -> some View { _accessibility { $0.label = label.plainString } }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { accessibilityLabel(Text(label)) }
    public func accessibilityLabel(_ key: LocalizedStringKey) -> some View { accessibilityLabel(Text(key)) }
    public func accessibilityLabel(_ label: Text, isEnabled: Bool) -> some View { _accessibility { if isEnabled { $0.label = label.plainString } } }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S, isEnabled: Bool) -> some View { accessibilityLabel(Text(label), isEnabled: isEnabled) }

    public func accessibilityValue(_ value: Text) -> some View { _accessibility { $0.value = value.plainString } }
    @_disfavoredOverload public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View { accessibilityValue(Text(value)) }
    public func accessibilityValue(_ key: LocalizedStringKey) -> some View { accessibilityValue(Text(key)) }

    public func accessibilityHint(_ hint: Text) -> some View { _accessibility { $0.hint = hint.plainString } }
    @_disfavoredOverload public func accessibilityHint<S: StringProtocol>(_ hint: S) -> some View { accessibilityHint(Text(hint)) }
    public func accessibilityHint(_ key: LocalizedStringKey) -> some View { accessibilityHint(Text(key)) }

    public func accessibilityIdentifier(_ identifier: String) -> some View { _accessibility { $0.identifier = identifier } }
    public func accessibilityIdentifier(_ identifier: String, isEnabled: Bool) -> some View { _accessibility { if isEnabled { $0.identifier = identifier } } }

    public func accessibilityHidden(_ hidden: Bool) -> some View { _accessibility { $0.isHidden = hidden } }
    public func accessibilityHidden(_ hidden: Bool, isEnabled: Bool) -> some View { _accessibility { if isEnabled { $0.isHidden = hidden } } }

    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { _accessibility { $0.children = children } }

    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { _accessibility { $0.addedTraits.formUnion(traits) } }
    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> some View { _accessibility { $0.removedTraits.formUnion(traits) } }
    public func accessibilitySortPriority(_ priority: Double) -> some View { _accessibility { $0.sortPriority = priority } }
    public func accessibilityHeading(_ level: AccessibilityHeadingLevel) -> some View {
        _accessibility { $0.headingLevel = level; $0.addedTraits.insert(.isHeader) }
    }

    public func accessibilityInputLabels(_ labels: [Text]) -> some View { _accessibility { $0.inputLabels = labels.map(\.plainString) } }
    @_disfavoredOverload public func accessibilityInputLabels<S: StringProtocol>(_ labels: [S]) -> some View { _accessibility { $0.inputLabels = labels.map { String($0) } } }
    public func accessibilityInputLabels(_ labels: [LocalizedStringKey]) -> some View { _accessibility { $0.inputLabels = labels.map(\.key) } }

    public func accessibilityRespondsToUserInteraction(_ responds: Bool = true) -> some View { _accessibility { $0.respondsToUserInteraction = responds } }
    public func accessibilityRespondsToUserInteraction(_ responds: Bool, isEnabled: Bool) -> some View {
        _accessibility { if isEnabled { $0.respondsToUserInteraction = responds } }
    }
    public func accessibilityTextContentType(_ type: AccessibilityTextContentType) -> some View { _accessibility { $0.textContentType = type } }

    public func accessibilityCustomContent(_ label: Text, _ value: Text, importance: AccessibilityCustomContentImportance = .default) -> some View {
        _accessibility { $0.customContent.append(AccessibilityCustomContentEntry(label: label.plainString, value: value.plainString, isImportant: importance == .high)) }
    }
    @_disfavoredOverload public func accessibilityCustomContent<S: StringProtocol, V: StringProtocol>(_ label: S, _ value: V, importance: AccessibilityCustomContentImportance = .default) -> some View {
        accessibilityCustomContent(Text(label), Text(value), importance: importance)
    }
    public func accessibilityCustomContent(_ label: LocalizedStringKey, _ value: Text, importance: AccessibilityCustomContentImportance = .default) -> some View {
        accessibilityCustomContent(Text(label), value, importance: importance)
    }

    public func accessibilityActivationPoint(_ point: UnitPoint) -> some View { _accessibility { $0.activationPoint = point } }
    public func accessibilityActivationPoint(_ point: CGPoint) -> some View { _accessibility { $0.activationPoint = UnitPoint(x: point.x, y: point.y) } }
    public func accessibilityDragPoint(_ point: UnitPoint, description: Text) -> some View { _accessibility { $0.dragPoint = point } }
    public func accessibilityDropPoint(_ point: UnitPoint, description: Text) -> some View { _accessibility { $0.dropPoint = point } }

    public func accessibilityLinkedGroup<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        _accessibility { $0.linkedGroup = AnyHashable(id) }
    }
    public func accessibilityLabeledPair<ID: Hashable>(role: AccessibilityLabeledPairRole, id: ID, in namespace: Namespace.ID) -> some View {
        _accessibility { $0.labeledPair = AnyHashable(id) }
    }
    public func accessibilityDefaultFocus<Value: Hashable>(_ binding: AccessibilityFocusState<Value>.Binding, _ value: Value) -> some View {
        _accessibility { $0.isDefaultFocus = true }
    }
    /// macOS has no direct-touch areas (iOS only); the trait is recorded.
    public func accessibilityDirectTouch(_ isDirectTouchArea: Bool = true, options: AccessibilityDirectTouchOptions = []) -> some View {
        _accessibility { if isDirectTouchArea { $0.addedTraits.insert(.allowsDirectInteraction) } }
    }
    /// Charts audio graphs are iOS-only; the descriptor is not used on macOS.
    public func accessibilityChartDescriptor<R>(_ representable: R) -> some View { self }
    public func accessibilityScrollStatus(_ status: Text, isEnabled: Bool = true) -> some View { _accessibility { if isEnabled { $0.value = status.plainString } } }
}

public struct AccessibilityDirectTouchOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let silentOnTouch = AccessibilityDirectTouchOptions(rawValue: 1)
    public static let requiresActivation = AccessibilityDirectTouchOptions(rawValue: 2)
}

// MARK: - Actions

extension View {
    public func accessibilityAction(_ actionKind: AccessibilityActionKind = .default, _ handler: @escaping @MainActor () -> Void) -> some View {
        _accessibilityAction(.standard(actionKind), handler: handler)
    }

    @_disfavoredOverload public func accessibilityAction<S: StringProtocol>(named name: S, _ handler: @escaping @MainActor () -> Void) -> some View {
        _accessibilityAction(.named(String(name)), handler: handler)
    }

    public func accessibilityAction(named name: Text, _ handler: @escaping @MainActor () -> Void) -> some View {
        _accessibilityAction(.named(name.plainString), handler: handler)
    }

    public func accessibilityAction<Label: View>(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) -> some View {
        _accessibilityAction(.named(MenuItems.title(of: label()).0), handler: action)
    }

    /// Buttons in `content` become named actions.
    public func accessibilityActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let items = MenuItems.items(content())
        return _accessibility { properties in
            for case let .button(title, _, _, _, _, action) in items {
                properties.actions.append(AccessibilityActionHandler(kind: .named(title), perform: action))
            }
        }
    }

    public func accessibilityAdjustableAction(_ handler: @escaping @MainActor (AccessibilityAdjustmentDirection) -> Void) -> some View {
        _accessibility { properties in
            properties.actions.append(AccessibilityActionHandler(kind: .adjust(.increment)) { handler(.increment) })
            properties.actions.append(AccessibilityActionHandler(kind: .adjust(.decrement)) { handler(.decrement) })
        }
    }

    public func accessibilityScrollAction(_ handler: @escaping @MainActor (Edge) -> Void) -> some View {
        _accessibility { properties in
            for edge in [Edge.top, .bottom, .leading, .trailing] {
                properties.actions.append(AccessibilityActionHandler(kind: .scroll(edge)) { handler(edge) })
            }
        }
    }

    public func accessibilityZoomAction(_ handler: @escaping @MainActor (AccessibilityZoomGestureAction) -> Void) -> some View {
        _accessibility { properties in
            for direction in [AccessibilityZoomGestureActionDirection.zoomIn, .zoomOut] {
                properties.actions.append(AccessibilityActionHandler(kind: .zoom(direction)) {
                    handler(AccessibilityZoomGestureAction(direction: direction, location: .center, point: .zero))
                })
            }
        }
    }
}

// MARK: - Representation and children

extension View {
    /// Uses the accessibility of `representation` (title, role) instead of this view's.
    public func accessibilityRepresentation<V: View>(@ViewBuilder representation: () -> V) -> some View {
        let view = representation()
        var title = MenuItems.title(of: view).0
        for item in MenuItems.items(view) {
            switch item {
            case let .button(itemTitle, _, _, _, _, _), let .toggle(itemTitle, _, _, _, _):
                if title.isEmpty { title = itemTitle }
            default: break
            }
        }
        let traits: AccessibilityTraits = view is any _AccessibilityButtonLike ? .isButton : []
        let actions: [AccessibilityActionHandler] = MenuItems.items(view).compactMap {
            if case let .button(_, _, _, _, _, action) = $0 { return AccessibilityActionHandler(kind: .standard(.default), perform: action) }
            return nil
        }
        return _accessibility { properties in
            properties.children = .ignore
            if !title.isEmpty { properties.label = title }
            properties.addedTraits.formUnion(traits)
            properties.actions.append(contentsOf: actions)
        }
    }

    /// Synthesized children: their labels become the element's custom content.
    public func accessibilityChildren<V: View>(@ViewBuilder children: () -> V) -> some View {
        let labels = _accessibilityLabels(of: children())
        return _accessibility { properties in
            properties.children = .contain
            properties.customContent.append(contentsOf: labels.map { AccessibilityCustomContentEntry(label: $0, value: "", isImportant: false) })
        }
    }
}

@MainActor protocol _AccessibilityButtonLike {}
extension Button: _AccessibilityButtonLike {}

/// Texts (and labels) of a view tree, for synthesized accessibility children.
@MainActor
func _accessibilityLabels(of view: any View) -> [String] {
    let (title, _) = MenuItems.title(of: view)
    if !title.isEmpty { return [title] }
    if let children = view as? _ChildrenReadable { return children._children.flatMap(_accessibilityLabels(of:)) }
    if let stack = view as? _StackContentReadable { return _accessibilityLabels(of: stack._stackContent) }
    return []
}

// MARK: - Accessibility focus

/// `@AccessibilityFocusState`: which element has assistive-technology focus.
@propertyWrapper
public struct AccessibilityFocusState<Value: Hashable>: DynamicProperty {
    @State private var value: Value

    public init(wrappedValue: Value) { _value = State(wrappedValue: wrappedValue) }
    public init() where Value == Bool { _value = State(wrappedValue: false) }
    public init<T: Hashable>() where Value == T? { _value = State(wrappedValue: nil) }
    public init(for technologies: AccessibilityTechnologies) where Value == Bool { _value = State(wrappedValue: false) }
    public init<T: Hashable>(for technologies: AccessibilityTechnologies) where Value == T? { _value = State(wrappedValue: nil) }

    public var wrappedValue: Value {
        get { value }
        nonmutating set { value = newValue }
    }

    public var projectedValue: Binding { Binding(value: $value) }

    @propertyWrapper
    public struct Binding {
        let value: _SwiftUICore.Binding<Value>
        public var wrappedValue: Value {
            get { value.wrappedValue }
            nonmutating set { value.wrappedValue = newValue }
        }
        public var projectedValue: Binding { self }
    }
}

public struct AccessibilityTechnologies: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let voiceOver = AccessibilityTechnologies(rawValue: 1)
    public static let switchControl = AccessibilityTechnologies(rawValue: 2)
}

extension View {
    public func accessibilityFocused<Value: Hashable>(_ binding: AccessibilityFocusState<Value>.Binding, equals value: Value) -> some View {
        _accessibility { $0.isDefaultFocus = binding.wrappedValue == value }
    }

    public func accessibilityFocused(_ condition: AccessibilityFocusState<Bool>.Binding) -> some View {
        _accessibility { $0.isDefaultFocus = condition.wrappedValue }
    }
}

// MARK: - Rotors (VoiceOver navigation; entries are recorded as custom content)

public struct AccessibilitySystemRotor: Sendable {
    let name: String
    public static let links = AccessibilitySystemRotor(name: "Links")
    public static let headings = AccessibilitySystemRotor(name: "Headings")
    public static let boldText = AccessibilitySystemRotor(name: "Bold Text")
    public static let italicText = AccessibilitySystemRotor(name: "Italic Text")
    public static let lists = AccessibilitySystemRotor(name: "Lists")
    public static let tables = AccessibilitySystemRotor(name: "Tables")
    public static let landmarks = AccessibilitySystemRotor(name: "Landmarks")
    public static let images = AccessibilitySystemRotor(name: "Images")
    public static let textFields = AccessibilitySystemRotor(name: "Text Fields")
    public static func headings(level: AccessibilityHeadingLevel) -> AccessibilitySystemRotor { .headings }
    public static func links(visited: Bool) -> AccessibilitySystemRotor { .links }
}

public struct AccessibilityRotorEntry<ID: Hashable> {
    let label: String
    public init(_ label: Text, id: ID, textRange: Range<String.Index>? = nil, prepare: @escaping () -> Void = {}) { self.label = label.plainString }
    @_disfavoredOverload public init<S: StringProtocol>(_ label: S, id: ID, textRange: Range<String.Index>? = nil, prepare: @escaping () -> Void = {}) { self.label = String(label) }
    public init(_ label: Text, id: ID, in namespace: Namespace.ID, textRange: Range<String.Index>? = nil, prepare: @escaping () -> Void = {}) { self.label = label.plainString }
}

@resultBuilder
public enum AccessibilityRotorContentBuilder {
    public static func buildExpression<ID>(_ entry: AccessibilityRotorEntry<ID>) -> [String] { [entry.label] }
    public static func buildExpression<Data, ID>(_ forEach: ForEach<Data, ID, AccessibilityRotorEntry<ID>>) -> [String] where Data: RandomAccessCollection {
        forEach.data.map { forEach.content($0).label }
    }
    public static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
    public static func buildArray(_ parts: [[String]]) -> [String] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [String]?) -> [String] { part ?? [] }
    public static func buildEither(first: [String]) -> [String] { first }
    public static func buildEither(second: [String]) -> [String] { second }
}

extension View {
    @_disfavoredOverload public func accessibilityRotor<S: StringProtocol>(_ label: S, @AccessibilityRotorContentBuilder entries: () -> [String]) -> some View {
        let entries = entries()
        let name = String(label)
        return _accessibility { $0.customContent.append(contentsOf: entries.map { AccessibilityCustomContentEntry(label: name, value: $0, isImportant: false) }) }
    }

    public func accessibilityRotor(_ label: Text, @AccessibilityRotorContentBuilder entries: () -> [String]) -> some View {
        accessibilityRotor(label.plainString, entries: entries)
    }

    public func accessibilityRotor(_ systemRotor: AccessibilitySystemRotor, @AccessibilityRotorContentBuilder entries: () -> [String]) -> some View {
        accessibilityRotor(systemRotor.name, entries: entries)
    }

    public func accessibilityRotorEntry<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View {
        _accessibility { $0.linkedGroup = AnyHashable(id) }
    }
}

#if !canImport(Accessibility)
/// Notifications for assistive technologies (Apple's Accessibility framework spelling). The backend posts
/// them (`AccessibilityNotification.poster`); without one they do nothing.
public enum AccessibilityNotification {
    /// What a backend receives for each post.
    public enum Kind: Sendable {
        case announcement(String)
        case layoutChanged
        case screenChanged
        case pageScrolled(String)
    }

    /// Installed by backends that talk to the platform's screen reader.
    nonisolated(unsafe) public static var poster: ((Kind) -> Void)?

    /// Speaks a message.
    public struct Announcement: Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public init(_ message: AttributedString) { self.message = String(message.characters) }
        public func post() { AccessibilityNotification.poster?(.announcement(message)) }
    }

    /// Part of the screen changed.
    public struct LayoutChanged: Sendable {
        public init() {}
        public init<Element>(_ element: Element?) {}
        public func post() { AccessibilityNotification.poster?(.layoutChanged) }
    }

    /// Most of the screen changed.
    public struct ScreenChanged: Sendable {
        public init() {}
        public init<Element>(_ element: Element?) {}
        public func post() { AccessibilityNotification.poster?(.screenChanged) }
    }

    /// A scroll finished; the message describes the new position.
    public struct PageScrolled: Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public func post() { AccessibilityNotification.poster?(.pageScrolled(message)) }
    }
}
#endif
