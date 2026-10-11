import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CoreTransferable)
import CoreTransferable
#endif

// MARK: - Focusable views


public struct FocusInteractions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let activate = FocusInteractions(rawValue: 1)
    public static let edit = FocusInteractions(rawValue: 2)
    public static let automatic: FocusInteractions = [.activate, .edit]
}

/// A view that can take keyboard focus (and then receives key presses and focus state).
public struct _FocusableModifier: ViewModifier {
    let isFocusable: Bool
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "focusable")
        let environment = inputs.environment
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let env = environment.value
            guard modifier.attribute.value.isFocusable else { return .effect(.group) }
            return .effect(.focusable(wantsFocus: env.focusRequest?.isFocused() ?? false, showsFocusRing: env.isFocusEffectEnabled))
        }
        var actions = RenderActions()
        actions.focusChanged = { focused in
            AnyAttribute.withoutDependencies { environment.value.focusRequest?.setFocused(focused) }
        }
        var childInputs = inputs
        childInputs.render = inputs.makePlatformNode(content: content, actions: actions)
        return body(childInputs)
    }
}

extension View {
    public func focusable(_ isFocusable: Bool = true) -> some View { modifier(_FocusableModifier(isFocusable: isFocusable)) }
    public func focusable(_ isFocusable: Bool = true, interactions: FocusInteractions) -> some View { modifier(_FocusableModifier(isFocusable: isFocusable)) }
    public func focusEffectDisabled(_ disabled: Bool = true) -> some View { environment(\.isFocusEffectEnabled, !disabled) }

    /// Focuses `value` when the view appears and nothing is focused yet.
    public func defaultFocus<V: Hashable>(_ binding: FocusState<V>.Binding, _ value: V, priority: DefaultFocusEvaluationPriority = .automatic) -> some View {
        onAppear {
            if _isUnfocused(binding.wrappedValue) { binding.wrappedValue = value }
        }
    }

    /// Focus sections and default-focus preferences steer the tvOS/visionOS focus engine; macOS
    /// moves keyboard focus through the key-view loop instead.
    public func focusSection() -> some View { self }
    public func prefersDefaultFocus(_ prefersDefaultFocus: Bool = true, in namespace: Namespace.ID) -> some View { self }
    public func focusScope(_ namespace: Namespace.ID) -> some View { self }
}

public struct DefaultFocusEvaluationPriority: Hashable, Sendable {
    let value: Int
    public static let automatic = DefaultFocusEvaluationPriority(value: 0)
    public static let userInitiated = DefaultFocusEvaluationPriority(value: 1)
}

/// `false` / `nil` focus values mean "nothing focused".
func _isUnfocused<V>(_ value: V) -> Bool {
    if let flag = value as? Bool { return !flag }
    if case Optional<Any>.none = value as Any? ?? nil { return true }
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional && mirror.children.isEmpty
}

// MARK: - Commands (responder-chain actions)

/// Handles a responder-chain action (`copy:`, `cut:`, `onCommand(#selector(...))`) while the view
/// exists; the most recently built handler for a selector wins.
struct _CommandModifier: PlatformEffectModifier {
    let selector: String
    let action: (@MainActor () -> Void)?
    static var pathComponent: String { "onCommand" }
    func effect(size: CGSize) -> DisplayEffect { .group }
    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        let selector = AnyAttribute.withoutDependencies { modifier.value.selector }
        actions.commands[selector] = { [weak modifier] in
            guard let modifier else { return false }
            guard let action = AnyAttribute.withoutDependencies({ modifier.value.action }) else { return false }
            action()
            return true
        }
        return actions
    }
}

extension View {
    #if canImport(ObjectiveC)
    /// macOS: performs `action` for the responder-chain action `selector` (e.g. a menu item's).
    public func onCommand(_ selector: Selector, perform action: (@MainActor () -> Void)?) -> some View {
        modifier(_CommandModifier(selector: NSStringFromSelector(selector), action: action))
    }
    #endif

    /// Edit > Copy: the items are written to the pasteboard.
    public func onCopyCommand(perform payloadAction: (@MainActor () -> [NSItemProvider])?) -> some View {
        modifier(_PasteboardWriteModifier(selector: "copy:", items: payloadAction.map { action in { action().map { $0 as Any } } }))
    }

    /// Edit > Cut: the items are written to the pasteboard (the action removes them).
    public func onCutCommand(perform payloadAction: (@MainActor () -> [NSItemProvider])?) -> some View {
        modifier(_PasteboardWriteModifier(selector: "cut:", items: payloadAction.map { action in { action().map { $0 as Any } } }))
    }

    #if canImport(CoreTransferable)
    /// Edit > Copy writes `payload`.
    public func copyable<T: Transferable>(_ payload: @autoclosure @escaping () -> [T]) -> some View {
        modifier(_PasteboardWriteModifier(selector: "copy:", items: { payload().map { _shareItem($0) } }))
    }

    /// Edit > Cut writes what `payloadAction` returns (it removes the items).
    public func cuttable<T: Transferable>(for payloadType: T.Type = T.self, action payloadAction: @escaping @MainActor () -> [T]) -> some View {
        modifier(_PasteboardWriteModifier(selector: "cut:", items: { payloadAction().map { _shareItem($0) } }))
    }

    /// Edit > Paste delivers pasteboard contents of `payloadType`.
    public func pasteDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping @MainActor ([T]) -> Void, validator: @escaping @MainActor ([T]) -> [T] = { $0 }) -> some View {
        let types = [UTType.fileURL, .url, .utf8PlainText, .plainText, .data, .image, .item].map(\.identifier)
        return modifier(_PasteCommandModifier(types: types, action: { providers in
            let providers = providers.compactMap { $0 as? NSItemProvider }
            guard !providers.isEmpty else { return }
            // Load every item, then deliver them together (in pasteboard order) on the main actor.
            let collector = _PasteCollector<T>(count: providers.count) { items in
                let valid = validator(items)
                if !valid.isEmpty { action(valid) }
            }
            for (index, provider) in providers.enumerated() {
                _ = provider.loadTransferable(type: T.self) { result in
                    let item = UncheckedSendable(try? result.get())
                    DispatchQueue.main.async { MainActor.assumeIsolated { collector.deliver(item.value, at: index) } }
                }
            }
        }))
    }
    #endif
}

/// Gathers asynchronously loaded paste items.
@MainActor
final class _PasteCollector<T> {
    private var items: [T?]
    private var remaining: Int
    private let completion: @MainActor ([T]) -> Void

    init(count: Int, completion: @escaping @MainActor ([T]) -> Void) {
        items = Array(repeating: nil, count: count)
        remaining = count
        self.completion = completion
    }

    func deliver(_ item: T?, at index: Int) {
        items[index] = item
        remaining -= 1
        if remaining == 0 { completion(items.compactMap { $0 }) }
    }
}

/// Writes items to the platform pasteboard for a responder-chain action.
struct _PasteboardWriteModifier: ViewModifier {
    let selector: String
    let items: (@MainActor () -> [Any])?
    @Environment(\._pasteboard) private var pasteboard

    func body(content: Content) -> some View {
        let pasteboard = self.pasteboard
        var action: (@MainActor () -> Void)?
        if let items {
            action = { pasteboard.write(items()) }
        }
        return content.modifier(_CommandModifier(selector: selector, action: action))
    }
}

/// Environment hook to the backend's pasteboard.
public struct PasteboardWriter: @unchecked Sendable {
    let write: @MainActor ([Any]) -> Void
}

struct PasteboardWriterKey: EnvironmentKey { static let defaultValue = PasteboardWriter { _ in } }

/// The system pasteboard for code outside a view, e.g. a "copy" helper (SwiftUI extension; SwiftUI
/// apps use `NSPasteboard`/`UIPasteboard`). Writes go through the most recently created view graph's backend.
@MainActor
public final class Pasteboard {
    public static let general = Pasteboard()
    weak var backend: (any RenderBackend)?

    /// Replaces the pasteboard's contents with items (strings, URLs, images…).
    public func setItems(_ items: [Any]) { backend?.writeToPasteboard(items) }
    public func setString(_ string: String) { setItems([string]) }
}

extension EnvironmentValues {
    public var _pasteboard: PasteboardWriter {
        get { self[PasteboardWriterKey.self] }
        set { self[PasteboardWriterKey.self] = newValue }
    }
}

extension ViewGraph {
    /// Whether some view handles the responder-chain action `selector`.
    public func canHandleCommand(_ selector: String) -> Bool { commandHandler(for: selector) != nil }

    /// Performs the responder-chain action `selector`; false when no view handles it.
    @discardableResult
    public func handleCommand(_ selector: String) -> Bool {
        guard let handler = commandHandler(for: selector) else { return false }
        let handled = handler()
        update()
        return handled
    }

    private func commandHandler(for selector: String) -> (@MainActor () -> Bool)? {
        var handler: (@MainActor () -> Bool)?
        func visit(_ node: RenderNode) {
            if let candidate = node.actions.commands[selector] { handler = candidate }
            for child in node.children { visit(child) }
        }
        visit(renderer.root)
        return handler
    }
}

// MARK: - Modifier keys

/// One `onModifierKeysChanged` registration.
@MainActor
final class ModifierKeysObserver {
    var mask: EventModifiers = .all
    var action: (@MainActor (EventModifiers, EventModifiers) -> Void)?
    var last: EventModifiers = []
}

extension ViewGraph {
    /// The pressed modifier keys changed (backends forward flag changes).
    public func handleModifierFlags(_ modifiers: EventModifiers) {
        currentModifierFlags = modifiers
        for observer in modifierKeysObservers.values {
            let masked = modifiers.intersection(observer.mask)
            guard masked != observer.last else { continue }
            let old = observer.last
            observer.last = masked
            observer.action?(old, masked)
        }
        update()
    }
}

struct _ModifierKeysModifier: ViewModifier {
    let mask: EventModifiers
    let initial: Bool
    let action: @MainActor (EventModifiers, EventModifiers) -> Void
    @State private var observer = ModifierKeysObserver()

    func body(content: Content) -> some View {
        observer.mask = mask
        observer.action = action
        let observer = self.observer
        let initial = self.initial
        return content.modifier(_ModifierKeysRegistration(observer: observer, initial: initial))
    }
}

struct _ModifierKeysRegistration: ViewModifier {
    let observer: ModifierKeysObserver
    let initial: Bool
    typealias Body = Never

    static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let host = inputs.host
        let (observer, initial) = AnyAttribute.withoutDependencies { (modifier.attribute.value.observer, modifier.attribute.value.initial) }
        let key = ObjectIdentifier(observer)
        host.modifierKeysObservers[key] = observer
        observer.last = host.currentModifierFlags.intersection(observer.mask)
        if initial {
            let current = observer.last
            host.enqueueAfterUpdate { observer.action?(current, current) }
        }
        inputs.subgraph.onDestroy { [weak host] in host?.modifierKeysObservers[key] = nil }
        return body(inputs)
    }
}

extension View {
    public func onModifierKeysChanged(mask: EventModifiers = .all, initial: Bool = true, _ action: @escaping @MainActor (_ old: EventModifiers, _ new: EventModifiers) -> Void) -> some View {
        modifier(_ModifierKeysModifier(mask: mask, initial: initial, action: action))
    }

    /// Shows `alternate` instead of this view while `modifiers` are held (menu items show it as
    /// their alternate).
    public func modifierKeyAlternate<V: View>(_ modifiers: EventModifiers, @ViewBuilder _ alternate: () -> V) -> some View {
        _ModifierKeyAlternate(content: self, alternate: alternate(), modifiers: modifiers)
    }
}

struct _ModifierKeyAlternate<Content: View, Alternate: View>: View {
    let content: Content
    let alternate: Alternate
    let modifiers: EventModifiers
    @State private var held = false

    var body: some View {
        Group {
            if held { alternate } else { content }
        }
        .onModifierKeysChanged(mask: modifiers) { _, new in held = new.isSuperset(of: modifiers) }
    }
}

// MARK: - Pointer

/// Mouse pointer shapes (`pointerStyle`).
public enum PointerStyle: Hashable, Sendable {
    case `default`, link, grabIdle, grabActive, horizontalText, verticalText, rectSelection, zoomIn, zoomOut
    case columnResize, rowResize
    case frameResize(position: FrameResizePosition, directions: FrameResizeDirection.Set = .all)

    public static func columnResize(directions: HorizontalDirection.Set) -> PointerStyle { .columnResize }
    public static func rowResize(directions: VerticalDirection.Set) -> PointerStyle { .rowResize }
}

public enum FrameResizePosition: Hashable, Sendable { case top, leading, bottom, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing }
public enum FrameResizeDirection: Hashable, Sendable {
    case inward, outward
    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let inward = Set(rawValue: 1), outward = Set(rawValue: 2)
        public static let all: Set = [.inward, .outward]
    }
}
public enum HorizontalDirection: Hashable, Sendable {
    case leading, trailing
    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let leading = Set(rawValue: 1), trailing = Set(rawValue: 2)
        public static let all: Set = [.leading, .trailing]
    }
}
public enum VerticalDirection: Hashable, Sendable {
    case up, down
    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let up = Set(rawValue: 1), down = Set(rawValue: 2)
        public static let all: Set = [.up, .down]
    }
}

public struct _PointerModifier: ViewModifier {
    let style: PointerStyle?
    let isHidden: Bool
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "pointerStyle")
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let current = modifier.attribute.value
            return .effect(.pointer(current.style, hidden: current.isHidden))
        }
        var childInputs = inputs
        childInputs.render = inputs.makePlatformNode(content: content)
        return body(childInputs)
    }
}

extension View {
    public func pointerStyle(_ style: PointerStyle?) -> some View { modifier(_PointerModifier(style: style, isHidden: false)) }
    public func pointerVisibility(_ visibility: Visibility) -> some View { modifier(_PointerModifier(style: nil, isHidden: visibility == .hidden)) }
}

// MARK: - Sensory feedback

/// Haptic feedback (the Force Touch trackpad on macOS).
public struct SensoryFeedback: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case success, warning, error, selection, increase, decrease, start, stop, alignment, levelChange, pathComplete, impact }
    public let kind: Kind

    public static let success = SensoryFeedback(kind: .success), warning = SensoryFeedback(kind: .warning), error = SensoryFeedback(kind: .error)
    public static let selection = SensoryFeedback(kind: .selection), increase = SensoryFeedback(kind: .increase), decrease = SensoryFeedback(kind: .decrease)
    public static let start = SensoryFeedback(kind: .start), stop = SensoryFeedback(kind: .stop)
    public static let alignment = SensoryFeedback(kind: .alignment), levelChange = SensoryFeedback(kind: .levelChange), pathComplete = SensoryFeedback(kind: .pathComplete)
    public static func impact(weight: Weight = .medium, intensity: Double = 1) -> SensoryFeedback { SensoryFeedback(kind: .impact) }
    public static func impact(flexibility: Flexibility, intensity: Double = 1) -> SensoryFeedback { SensoryFeedback(kind: .impact) }

    public struct Weight: Hashable, Sendable {
        public static let light = Weight(), medium = Weight(), heavy = Weight()
    }
    public struct Flexibility: Hashable, Sendable {
        public static let rigid = Flexibility(), solid = Flexibility(), soft = Flexibility()
    }
}

/// Environment hook to the backend's haptic feedback.
public struct HapticPerformer: @unchecked Sendable {
    let perform: @MainActor (SensoryFeedback) -> Void
}

struct HapticPerformerKey: EnvironmentKey { static let defaultValue = HapticPerformer { _ in } }

extension EnvironmentValues {
    public var _haptics: HapticPerformer {
        get { self[HapticPerformerKey.self] }
        set { self[HapticPerformerKey.self] = newValue }
    }
}

struct _SensoryFeedbackModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let feedback: @MainActor (T, T) -> SensoryFeedback?
    @Environment(\._haptics) private var haptics

    func body(content: Content) -> some View {
        let haptics = self.haptics
        let feedback = self.feedback
        content.onChange(of: trigger) { old, new in
            if let value = feedback(old, new) { haptics.perform(value) }
        }
    }
}

extension View {
    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(_SensoryFeedbackModifier(trigger: trigger) { _, _ in feedback })
    }

    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, condition: @escaping @MainActor (_ oldValue: T, _ newValue: T) -> Bool) -> some View {
        modifier(_SensoryFeedbackModifier(trigger: trigger) { condition($0, $1) ? feedback : nil })
    }

    public func sensoryFeedback<T: Equatable>(trigger: T, _ feedback: @escaping @MainActor (_ oldValue: T, _ newValue: T) -> SensoryFeedback?) -> some View {
        modifier(_SensoryFeedbackModifier(trigger: trigger, feedback: feedback))
    }
}

// MARK: - Submit scope

extension View {
    /// Submits inside the content don't trigger `onSubmit` actions outside it.
    public func submitScope(_ isBlocking: Bool = true) -> some View {
        transformEnvironment(\.submitAction) { if isBlocking { $0 = nil } }
    }
}

// MARK: - Find navigator (text editors)

struct FindDisabledKey: EnvironmentKey { static let defaultValue = false }
struct ReplaceDisabledKey: EnvironmentKey { static let defaultValue = false }
struct FindNavigatorKey: EnvironmentKey { static let defaultValue: Binding<Bool>? = nil }

extension EnvironmentValues {
    var findDisabled: Bool {
        get { self[FindDisabledKey.self] }
        set { self[FindDisabledKey.self] = newValue }
    }
    var replaceDisabled: Bool {
        get { self[ReplaceDisabledKey.self] }
        set { self[ReplaceDisabledKey.self] = newValue }
    }
    var findNavigatorPresented: Binding<Bool>? {
        get { self[FindNavigatorKey.self] }
        set { self[FindNavigatorKey.self] = newValue }
    }
}

public enum FindContext: Hashable, Sendable { case find, replace }

extension View {
    /// Shows or hides the find bar of text editors in the content.
    public func findNavigator(isPresented: Binding<Bool>) -> some View { environment(\.findNavigatorPresented, isPresented) }
    public func findDisabled(_ isDisabled: Bool = true) -> some View { environment(\.findDisabled, isDisabled) }
    /// The AppKit find bar's replace field follows the editor's editability; recorded only.
    public func replaceDisabled(_ isDisabled: Bool = true) -> some View { environment(\.replaceDisabled, isDisabled) }
}

// MARK: - Menu presentation details

public enum MenuOrder: Hashable, Sendable { case automatic, priority, fixed }
public struct MenuActionDismissBehavior: Hashable, Sendable {
    let dismisses: Bool
    public static let automatic = MenuActionDismissBehavior(dismisses: true)
    public static let enabled = MenuActionDismissBehavior(dismisses: true)
    public static let disabled = MenuActionDismissBehavior(dismisses: false)
}

extension View {
    /// macOS menus always list items in declaration order (priority ordering is an iOS layout).
    public func menuOrder(_ order: MenuOrder) -> some View { self }
    /// NSMenu closes after an action; menus that stay open are an iOS/visionOS behavior.
    public func menuActionDismissBehavior(_ behavior: MenuActionDismissBehavior) -> some View { self }
}
