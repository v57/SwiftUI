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

// MARK: - Key presses

/// Mirrors `SwiftUI.KeyPress`.
public struct KeyPress: Sendable {
    public struct Phases: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let down = Phases(rawValue: 1)
        public static let `repeat` = Phases(rawValue: 2)
        public static let up = Phases(rawValue: 4)
        public static let all: Phases = [.down, .repeat, .up]
    }

    public enum Result: Sendable { case handled, ignored }

    public let key: KeyEquivalent
    public let characters: String
    public let modifiers: EventModifiers
    public let phase: Phases

    public init(key: KeyEquivalent, characters: String, modifiers: EventModifiers, phase: Phases) {
        self.key = key
        self.characters = characters
        self.modifiers = modifiers
        self.phase = phase
    }
}

public enum MoveCommandDirection: Sendable { case up, down, left, right }

struct _KeyPressModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let phases: KeyPress.Phases
    let matches: @MainActor (KeyPress) -> Bool
    let action: @MainActor (KeyPress) -> KeyPress.Result

    static var pathComponent: String { "onKeyPress" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.keyPress = { [weak modifier] press in
            guard let modifier else { return .ignored }
            return AnyAttribute.withoutDependencies {
                let value = modifier.value
                guard value.phases.contains(press.phase), value.matches(press) else { return .ignored }
                return value.action(press)
            }
        }
        return actions
    }
}

extension View {
    public func onKeyPress(_ key: KeyEquivalent, action: @escaping @MainActor () -> KeyPress.Result) -> some View {
        modifier(_KeyPressModifier(phases: [.down, .repeat], matches: { $0.key == key }, action: { _ in action() }))
    }

    public func onKeyPress(_ key: KeyEquivalent, phases: KeyPress.Phases, action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        modifier(_KeyPressModifier(phases: phases, matches: { $0.key == key }, action: action))
    }

    public func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat], action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        modifier(_KeyPressModifier(phases: phases, matches: { keys.contains($0.key) }, action: action))
    }

    public func onKeyPress(characters: CharacterSet, phases: KeyPress.Phases = [.down, .repeat], action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        modifier(_KeyPressModifier(phases: phases, matches: { press in
            press.characters.unicodeScalars.allSatisfy { characters.contains($0) } && !press.characters.isEmpty
        }, action: action))
    }

    public func onKeyPress(phases: KeyPress.Phases = [.down, .repeat], action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        modifier(_KeyPressModifier(phases: phases, matches: { _ in true }, action: action))
    }

    /// Escape (macOS "cancel operation").
    public func onExitCommand(perform action: (@MainActor () -> Void)?) -> some View {
        modifier(_KeyPressModifier(phases: .down, matches: { $0.key == .escape }, action: { _ in
            guard let action else { return .ignored }
            action()
            return .handled
        }))
    }

    public func onMoveCommand(perform action: (@MainActor (MoveCommandDirection) -> Void)?) -> some View {
        modifier(_KeyPressModifier(phases: [.down, .repeat], matches: { [.upArrow, .downArrow, .leftArrow, .rightArrow].contains($0.key) }, action: { press in
            guard let action else { return .ignored }
            switch press.key {
            case .upArrow: action(.up)
            case .downArrow: action(.down)
            case .leftArrow: action(.left)
            default: action(.right)
            }
            return .handled
        }))
    }

    public func onDeleteCommand(perform action: (@MainActor () -> Void)?) -> some View {
        modifier(_KeyPressModifier(phases: .down, matches: { $0.key == .delete || $0.key == .deleteForward }, action: { _ in
            guard let action else { return .ignored }
            action()
            return .handled
        }))
    }
}

#if canImport(UniformTypeIdentifiers)
extension View {
    /// Edit > Paste routed to this view: the pasteboard contents as item providers.
    public func onPasteCommand(of supportedContentTypes: [UTType], perform action: @escaping @MainActor ([NSItemProvider]) -> Void) -> some View {
        modifier(_PasteCommandModifier(types: supportedContentTypes.map(\.identifier), action: { action($0.compactMap { $0 as? NSItemProvider }) }))
    }
}
#endif

struct _PasteCommandModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let types: [String]
    let action: @MainActor ([AnyObject]) -> Void
    static var pathComponent: String { "onPasteCommand" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }
    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.pasteTypes = AnyAttribute.withoutDependencies { modifier.value.types }
        actions.paste = { [weak modifier] providers in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.action(providers) }
        }
        return actions
    }
}

// MARK: - Transferable drag & drop

#if canImport(CoreTransferable)
struct TransferableDropHandler<T: Transferable>: _DropHandler {
    let action: @MainActor ([T], CGPoint) -> Bool
    let isTargeted: @MainActor (Bool) -> Void
    func targeted(_ value: Bool) { isTargeted(value) }
    func updated(location: CGPoint) {}
    func perform(providers: [AnyObject], location: CGPoint, types: [String]) -> Bool {
        let providers = providers.compactMap { $0 as? NSItemProvider }
        guard !providers.isEmpty else { return false }
        let action = UncheckedSendable(action)
        let boxes = UncheckedSendable(providers)
        Task { @MainActor in
            var items: [T] = []
            for provider in boxes.value {
                if let item = await Self.load(provider) { items.append(item) }
            }
            if !items.isEmpty { _ = action.value(items, location) }
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> T? {
        let item = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedSendable<T?>, Never>) in
            _ = provider.loadTransferable(type: T.self) { result in
                continuation.resume(returning: UncheckedSendable(try? result.get()))
            }
        }
        return item.value
    }
}

extension View {
    public func draggable<T: Transferable>(_ payload: @autoclosure @escaping () -> T) -> some View {
        modifier(_DragModifier(makeItem: {
            let provider = NSItemProvider()
            let value = UncheckedSendable(payload())
            provider.register(value.value)
            return provider
        }))
    }

    public func draggable<T: Transferable, V: View>(_ payload: @autoclosure @escaping () -> T, @ViewBuilder preview: () -> V) -> some View {
        draggable(payload())
    }

    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping @MainActor (_ items: [T], _ location: CGPoint) -> Bool, isTargeted: @escaping @MainActor (Bool) -> Void = { _ in }) -> some View {
        // Transferable doesn't expose its content types; accept the common ones and let the
        // payload type's import decide.
        let types = [UTType.fileURL, .url, .utf8PlainText, .plainText, .data, .image, .item].map(\.identifier)
        return modifier(_DropModifier(types: types, isTargeted: nil, delegate: TransferableDropHandler(action: action, isTargeted: isTargeted)))
    }
}
#endif

// MARK: - Styles and small modifiers

/// Menu styles: built-in presentations or a custom `makeBody(configuration:)`.
@MainActor @preconcurrency
public protocol MenuStyle {
    associatedtype Body: View
    typealias Configuration = MenuStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    var _isBuiltin: Bool { get }
}

extension MenuStyle {
    public var _isBuiltin: Bool { false }
}

public struct MenuStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
    let label: Label
    let content: Content
}

public struct DefaultMenuStyle: MenuStyle {
    public init() {}
    public var _isBuiltin: Bool { true }
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}
public struct BorderlessButtonMenuStyle: MenuStyle {
    public init() {}
    public var _isBuiltin: Bool { true }
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration).environment(\.menuIsBorderless, true) }
}
public struct ButtonMenuStyle: MenuStyle {
    public init() {}
    public var _isBuiltin: Bool { true }
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}
public struct BorderedButtonMenuStyle: MenuStyle {
    public init() {}
    public var _isBuiltin: Bool { true }
    public func makeBody(configuration: Configuration) -> some View { Menu(configuration) }
}
extension MenuStyle where Self == DefaultMenuStyle { public static var automatic: DefaultMenuStyle { .init() } }
extension MenuStyle where Self == BorderlessButtonMenuStyle { public static var borderlessButton: BorderlessButtonMenuStyle { .init() } }
extension MenuStyle where Self == ButtonMenuStyle { public static var button: ButtonMenuStyle { .init() } }
extension MenuStyle where Self == BorderedButtonMenuStyle { public static var borderedButton: BorderedButtonMenuStyle { .init() } }

struct MenuBorderlessKey: EnvironmentKey { static let defaultValue = false }
struct MenuIndicatorKey: EnvironmentKey { static let defaultValue = Visibility.automatic }

extension EnvironmentValues {
    var menuIsBorderless: Bool {
        get { self[MenuBorderlessKey.self] }
        set { self[MenuBorderlessKey.self] = newValue }
    }
    var menuIndicatorVisibility: Visibility {
        get { self[MenuIndicatorKey.self] }
        set { self[MenuIndicatorKey.self] = newValue }
    }
}

public protocol DatePickerStyle { var _kind: DatePickerStyleKind { get } }
public struct DefaultDatePickerStyle: DatePickerStyle { public init() {}; public var _kind: DatePickerStyleKind { .automatic } }
public struct FieldDatePickerStyle: DatePickerStyle { public init() {}; public var _kind: DatePickerStyleKind { .field } }
public struct StepperFieldDatePickerStyle: DatePickerStyle { public init() {}; public var _kind: DatePickerStyleKind { .stepperField } }
public struct CompactDatePickerStyle: DatePickerStyle { public init() {}; public var _kind: DatePickerStyleKind { .compact } }
public struct GraphicalDatePickerStyle: DatePickerStyle { public init() {}; public var _kind: DatePickerStyleKind { .graphical } }

struct DatePickerStyleKey: EnvironmentKey { static let defaultValue = DatePickerStyleKind.automatic }
extension EnvironmentValues {
    var datePickerStyle: DatePickerStyleKind {
        get { self[DatePickerStyleKey.self] }
        set { self[DatePickerStyleKey.self] = newValue }
    }
}
extension DatePickerStyle where Self == DefaultDatePickerStyle { public static var automatic: DefaultDatePickerStyle { .init() } }
extension DatePickerStyle where Self == FieldDatePickerStyle { public static var field: FieldDatePickerStyle { .init() } }
extension DatePickerStyle where Self == StepperFieldDatePickerStyle { public static var stepperField: StepperFieldDatePickerStyle { .init() } }
extension DatePickerStyle where Self == CompactDatePickerStyle { public static var compact: CompactDatePickerStyle { .init() } }
extension DatePickerStyle where Self == GraphicalDatePickerStyle { public static var graphical: GraphicalDatePickerStyle { .init() } }

/// macOS 26 Liquid Glass description (rendered as a translucent material).
public struct Glass: Sendable {
    var tint: Color?
    var isInteractive = false
    public static let regular = Glass()
    public static let clear = Glass()
    public static let identity = Glass()
    public func tint(_ color: Color?) -> Glass { var copy = self; copy.tint = color; return copy }
    public func interactive(_ isEnabled: Bool = true) -> Glass { var copy = self; copy.isInteractive = isEnabled; return copy }
}

public struct GlassEffectContainer<Content: View>: View {
    let content: Content
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content }
}

public enum ScrollBounceBehavior: Sendable { case automatic, always, basedOnSize }
public protocol ScrollTargetBehavior {}
public struct PagingScrollTargetBehavior: ScrollTargetBehavior { public init() {} }
public struct ViewAlignedScrollTargetBehavior: ScrollTargetBehavior { public init() {} }
extension ScrollTargetBehavior where Self == PagingScrollTargetBehavior { public static var paging: PagingScrollTargetBehavior { .init() } }
extension ScrollTargetBehavior where Self == ViewAlignedScrollTargetBehavior { public static var viewAligned: ViewAlignedScrollTargetBehavior { .init() } }

extension View {
    public func menuStyle<S: MenuStyle>(_ style: S) -> some View {
        transformEnvironment(\.self) { environment in
            environment[style: MenuStyleConfiguration.self] = style._isBuiltin ? nil : _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) }
            environment.menuIsBorderless = style is BorderlessButtonMenuStyle
        }
    }

    public func menuIndicator(_ visibility: Visibility) -> some View {
        environment(\.menuIndicatorVisibility, visibility)
    }

    public func datePickerStyle<S: DatePickerStyle>(_ style: S) -> some View { environment(\.datePickerStyle, style._kind) }

    public func fontDesign(_ design: Font.Design?) -> some View {
        transformEnvironment(\.font) { font in
            var resolved = font ?? .defaultFont
            resolved.design = design ?? .default
            font = resolved
        }
    }

    /// macOS 26 bar-style safe area inset (laid out like `safeAreaInset`).
    public func safeAreaBar<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
        safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
    }

    public func safeAreaBar<V: View>(edge: HorizontalEdge, alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
        safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
    }

    public func glassEffect<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        background {
            ZStack {
                shape.fill(.regularMaterial)
                if let tint = glass.tint { shape.fill(tint.opacity(0.25)) }
                shape.stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            }
        }
    }

    public func glassEffect(_ glass: Glass = .regular) -> some View {
        glassEffect(glass, in: Capsule())
    }

    public func glassEffectID<ID: Hashable>(_ id: ID?, in namespace: Namespace.ID) -> some View { self }

    public func scrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View {
        modifier(_ScrollPositionModifier(id: id, anchor: anchor))
    }

    public func scrollTargetLayout(isEnabled: Bool = true) -> some View { self }

    public func matchedTransitionSource<ID: Hashable>(id: ID, in namespace: Namespace.ID) -> some View { self }
}

/// Scrolls the enclosed scroll view to the bound id whenever it changes (programmatic only).
struct _ScrollPositionModifier<ID: Hashable>: ViewModifier {
    @Binding var id: ID?
    let anchor: UnitPoint?
    @State private var box = ScrollProxyBox()
    @State private var reported: ID?

    func body(content: Content) -> some View {
        content
            .environment(\.scrollProxyBox, box)
            .onChange(of: id, initial: true) { _, newValue in
                // Ids reported from user scrolling don't scroll back.
                guard let newValue, newValue != reported else { return }
                ScrollViewProxy(box: box).scrollTo(newValue, anchor: anchor)
            }
            .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, visible in
                // The binding follows scrolling: the first target whose frame reaches into view.
                guard let targets = box.targets else { return }
                let vertical = targets.axes.contains(.vertical)
                let first = targets.allIDs.compactMap { key -> (ID, CGFloat)? in
                    guard let typed = key.base as? ID, let frame = targets.frame(for: key) else { return nil }
                    let visibleEnd = vertical ? frame.maxY > visible.minY + 0.5 : frame.maxX > visible.minX + 0.5
                    return visibleEnd ? (typed, vertical ? frame.minY : frame.minX) : nil
                }.min { $0.1 < $1.1 }?.0
                guard let first, first != id else { return }
                reported = first
                id = first
            }
    }
}

/// A scroll view's position: an edge, a view id or a point (`scrollPosition(_:)`).
public struct ScrollPosition: Equatable {
    enum Target: Equatable {
        case none
        case edge(Edge)
        case id(AnyHashable, UnitPoint?)
        case point(CGPoint)
        case x(CGFloat)
        case y(CGFloat)
    }

    var target: Target
    /// Bumped by every `scrollTo` so repeated requests scroll again.
    var request = 0
    public private(set) var isPositionedByUser = false
    /// The current offset (updated as the scroll view scrolls).
    var offset: CGPoint?

    public init<T: Hashable>(idType: T.Type = Never.self) { target = .none }
    public init<T: Hashable>(idType: T.Type = Never.self, edge: Edge) { target = .edge(edge) }
    public init<T: Hashable>(idType: T.Type = Never.self, point: CGPoint) { target = .point(point) }
    public init<T: Hashable>(idType: T.Type = Never.self, x: CGFloat) { target = .x(x) }
    public init<T: Hashable>(idType: T.Type = Never.self, y: CGFloat) { target = .y(y) }
    public init(id: some Hashable, anchor: UnitPoint? = nil) { target = .id(AnyHashable(id), anchor) }

    public var edge: Edge? { if case .edge(let edge) = target { edge } else { nil } }
    public var point: CGPoint? {
        switch target {
        case .point(let point): point
        default: isPositionedByUser ? offset : nil
        }
    }
    public var viewID: AnyHashable? { if case .id(let id, _) = target { id } else { nil } }
    public func viewID<T: Hashable>(type: T.Type) -> T? { viewID?.base as? T }

    public mutating func scrollTo(edge: Edge) { set(.edge(edge)) }
    public mutating func scrollTo(id: some Hashable, anchor: UnitPoint? = nil) { set(.id(AnyHashable(id), anchor)) }
    public mutating func scrollTo(point: CGPoint) { set(.point(point)) }
    public mutating func scrollTo(x: CGFloat) { set(.x(x)) }
    public mutating func scrollTo(y: CGFloat) { set(.y(y)) }

    private mutating func set(_ target: Target) {
        self.target = target
        request += 1
        isPositionedByUser = false
    }

    mutating func userScrolled(to offset: CGPoint, viewID: AnyHashable?) {
        self.offset = offset
        isPositionedByUser = true
        target = viewID.map { .id($0, nil) } ?? .point(offset)
    }
}

struct _ScrollPositionBindingModifier: ViewModifier {
    @Binding var position: ScrollPosition
    let anchor: UnitPoint?
    @State private var box = ScrollProxyBox()
    @State private var geometry: ScrollGeometry?
    @State private var lastRequest = -1

    func body(content: Content) -> some View {
        content
            .environment(\.scrollProxyBox, box)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in
                geometry = new
                if lastRequest != position.request {
                    perform()
                } else if position.offset != new.contentOffset {
                    position.userScrolled(to: new.contentOffset, viewID: firstVisibleID(in: new.visibleRect))
                }
            }
            .onChange(of: position.request, initial: true) { perform() }
    }

    private func firstVisibleID(in visible: CGRect) -> AnyHashable? {
        guard let targets = box.targets else { return nil }
        let vertical = targets.axes.contains(.vertical)
        return targets.allIDs.compactMap { key -> (AnyHashable, CGFloat)? in
            guard let frame = targets.frame(for: key) else { return nil }
            return (vertical ? frame.maxY > visible.minY + 0.5 : frame.maxX > visible.minX + 0.5) ? (key, vertical ? frame.minY : frame.minX) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    private func perform() {
        guard let targets = box.targets, let geometry else { return }
        lastRequest = position.request
        let size = geometry.containerSize
        let content = geometry.contentSize
        var frame: CGRect?
        var targetAnchor: UnitPoint? = .topLeading
        switch position.target {
        case .none: return
        case .edge(.top): frame = CGRect(x: geometry.contentOffset.x, y: 0, width: 1, height: 1)
        case .edge(.bottom): frame = CGRect(x: geometry.contentOffset.x, y: max(0, content.height - 1), width: 1, height: 1); targetAnchor = .bottom
        case .edge(.leading): frame = CGRect(x: 0, y: geometry.contentOffset.y, width: 1, height: 1)
        case .edge(.trailing): frame = CGRect(x: max(0, content.width - 1), y: geometry.contentOffset.y, width: 1, height: 1); targetAnchor = .trailing
        case .id(let id, let anchor):
            frame = targets.frame(for: id)
            targetAnchor = anchor ?? self.anchor
        case .point(let point): frame = CGRect(origin: point, size: size)
        case .x(let x): frame = CGRect(x: x, y: geometry.contentOffset.y, width: size.width, height: size.height)
        case .y(let y): frame = CGRect(x: geometry.contentOffset.x, y: y, width: size.width, height: size.height)
        }
        guard let frame else { return }
        targets.scroll?(frame, targetAnchor)
        position.offset = nil
    }
}

extension View {
    /// Binds the scroll view's position (scrolls when it is set; follows user scrolling).
    public func scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint? = nil) -> some View {
        modifier(_ScrollPositionBindingModifier(position: position, anchor: anchor))
    }
}

// MARK: - Text decoration for all contained text

struct TextStrikethroughKey: EnvironmentKey { static let defaultValue: Text.LineStyle? = nil }
struct TextUnderlineKey: EnvironmentKey { static let defaultValue: Text.LineStyle? = nil }

extension EnvironmentValues {
    /// Line style for all contained text (nil: none).
    var textStrikethrough: Text.LineStyle? {
        get { self[TextStrikethroughKey.self] }
        set { self[TextStrikethroughKey.self] = newValue }
    }
    var textUnderline: Text.LineStyle? {
        get { self[TextUnderlineKey.self] }
        set { self[TextUnderlineKey.self] = newValue }
    }
}

extension View {
    public func strikethrough(_ isActive: Bool = true, pattern: Text.LineStyle.Pattern = .solid, color: Color? = nil) -> some View {
        environment(\.textStrikethrough, isActive ? Text.LineStyle(pattern: pattern, color: color) : nil)
    }

    public func underline(_ isActive: Bool = true, pattern: Text.LineStyle.Pattern = .solid, color: Color? = nil) -> some View {
        environment(\.textUnderline, isActive ? Text.LineStyle(pattern: pattern, color: color) : nil)
    }
}
