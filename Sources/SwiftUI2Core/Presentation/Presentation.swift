import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A modal or anchored presentation shown in the host's presentation layer (above the root view).
/// Presentations are rendered with SwiftUI2 views, so every backend gets them for free.
@MainActor
final class PresentationEntry {
    enum Kind: Equatable {
        case sheet
        case alert
        case confirmationDialog
        case popover
        case menu
    }

    let id: Int
    let kind: Kind
    /// Builds the presented content (with the presenter's environment).
    let make: @MainActor (_ViewInputs) -> _ViewOutputs
    let environment: Attribute<EnvironmentValues>
    /// Presenter frame in host coordinates (anchored presentations).
    let anchor: Attribute<ViewGeometry>?
    let dismiss: @MainActor () -> Void
    /// The content's `PresentationAppearance` (observed by the chrome): blocks or confirms
    /// interactive dismissal, sets background, corner radius and sizing.
    let appearanceBox = _PresentationAppearanceBox()
    var appearance: PresentationAppearance { appearanceBox.appearance }

    /// Escape key / click outside: honors `interactiveDismissDisabled` and
    /// `dismissalConfirmationDialog`.
    func interactiveDismiss() {
        if let confirm = appearance.dismissConfirmation { confirm(); return }
        if appearance.isInteractiveDismissDisabled { return }
        dismiss()
    }

    init(id: Int, kind: Kind, environment: Attribute<EnvironmentValues>, anchor: Attribute<ViewGeometry>?, dismiss: @escaping @MainActor () -> Void, make: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) {
        self.id = id
        self.kind = kind
        self.environment = environment
        self.anchor = anchor
        self.dismiss = dismiss
        self.make = make
    }
}

@MainActor
final class PresentationRegistry {
    let entries: Attribute<[PresentationEntry]>
    private var nextID = 0

    init(subgraph: Subgraph) {
        entries = Attribute(subgraph, value: [], isEqual: { lhs, rhs in lhs.map(\.id) == rhs.map(\.id) })
    }

    func makeID() -> Int {
        nextID += 1
        return nextID
    }

    func present(_ entry: PresentationEntry) {
        guard !(entries.peekValue ?? []).contains(where: { $0.id == entry.id }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            entries.setValue((entries.peekValue ?? []) + [entry])
        }
    }

    func remove(id: Int) {
        guard (entries.peekValue ?? []).contains(where: { $0.id == id }) else { return }
        withAnimation(.easeIn(duration: 0.12)) {
            entries.setValue((entries.peekValue ?? []).filter { $0.id != id })
        }
    }

    var top: PresentationEntry? { entries.peekValue?.last }
}

extension _ViewInputs {
    /// Registers a presentation driven by `isPresented` (evaluated in an eager observer).
    func makePresentation(
        kind: PresentationEntry.Kind,
        isPresented: @escaping @MainActor () -> Bool,
        setPresented: @escaping @MainActor (Bool) -> Void,
        onDismiss: @escaping @MainActor () -> Void = {},
        make: @escaping @MainActor (_ViewInputs) -> _ViewOutputs
    ) {
        let host = self.host
        let registry = host.presentations!
        let id = registry.makeID()
        let presenterEnvironment = environment
        let dismiss: @MainActor () -> Void = { setPresented(false) }
        let contentEnvironment = Attribute<EnvironmentValues>(subgraph) {
            var env = presenterEnvironment.value
            env.dismiss = DismissAction(action: dismiss)
            env.isPresented = true
            if kind == .menu || kind == .alert || kind == .confirmationDialog {
                env.buttonDismissAction = dismiss
            }
            return env
        }
        let entry = PresentationEntry(id: id, kind: kind, environment: contentEnvironment, anchor: geometry, dismiss: dismiss, make: make)
        let observer = Attribute<Bool>(subgraph, isEqual: { $0 == $1 }) { isPresented() }
        observer.order = depth
        var wasPresented = false
        observer.onChange = { presented in
            host.enqueueAfterUpdate {
                if presented {
                    registry.present(entry)
                } else {
                    registry.remove(id: id)
                    if wasPresented { onDismiss() }
                }
                wasPresented = presented
            }
        }
        observer.isEager = true
        subgraph.onDestroy { [weak host] in
            host?.enqueueAfterUpdate { registry.remove(id: id) }
        }
    }
}

struct ButtonDismissKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }

extension EnvironmentValues {
    /// Inside menus, alerts and dialogs, buttons dismiss the presentation after their action.
    var buttonDismissAction: (@MainActor () -> Void)? {
        get { self[ButtonDismissKey.self] }
        set { self[ButtonDismissKey.self] = newValue }
    }
}

// MARK: - Presentation layer

/// Root of the presentation tree (one per host, above the root view).
struct _PresentationLayer: View {
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let registry = inputs.host.presentations!
        let parent = inputs.subgraph
        let attribute = Attribute<ViewList>(inputs.subgraph, isEqual: ViewList.isStructurallyEqual) {
            let entries = registry.entries.value
            return ViewList(nodes: entries.map { entry in
                .nested(.explicit(AnyHashable(entry.id)), ViewList(element: ViewListElement { placement in
                    var inputs = placement
                    inputs.environment = entry.environment
                    let chrome = Attribute<_PresentationChrome>(placement.subgraph) {
                        // Only anchored presentations read the presenter's frame (a presenter
                        // inside another presentation lives in this layer).
                        _PresentationChrome(entry: entry, anchor: entry.kind == .popover || entry.kind == .menu ? entry.anchor?.value.frame : nil)
                    }
                    return _PresentationChrome._makeView(view: _GraphValue(chrome), inputs: inputs)
                }))
            })
        }
        _ = parent
        return inputs.makeLayoutContainer(layout: inputs.constant(_ZStackLayout(alignment: .topLeading)), list: ViewList(nodes: [.dynamic(nil, attribute)]))
    }
}

/// Content of an entry (calls the presenter's builder).
struct _PresentationContent: View {
    let entry: PresentationEntry
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let entry = AnyAttribute.withoutDependencies { view.attribute.value.entry }
        let outputs = entry.make(inputs.requesting(PresentationAppearanceKey.self))
        if let appearance = outputs.preferences[PresentationAppearanceKey.self] {
            let host = inputs.host
            let observer = Attribute<PresentationAppearance>(inputs.subgraph, isEqual: { $0 == $1 }) { appearance.value }
            observer.onChange = { value in host.enqueueAfterUpdate { entry.appearanceBox.appearance = value } }
            observer.isEager = true
        }
        return outputs
    }
}

extension _PresentationContent: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: _PresentationContent, _ rhs: _PresentationContent) -> Bool {
        MainActor.assumeIsolated { lhs.entry === rhs.entry }
    }
}

struct _PresentationChrome: View {
    let entry: PresentationEntry
    let anchor: CGRect?

    var body: some View {
        let entry = self.entry
        let appearance = entry.appearanceBox.appearance
        let radius = appearance.cornerRadius ?? 10
        switch entry.kind {
        case .sheet:
            ZStack {
                Color.black.opacity(0.25)
                _PresentationContent(entry: entry)
                    .frame(minWidth: appearance.sizing.minimumSize.width, idealWidth: appearance.sizing.idealSize?.width,
                           minHeight: appearance.sizing.minimumSize.height, idealHeight: appearance.sizing.idealSize?.height)
                    .background(RoundedRectangle(cornerRadius: radius).fill(appearance.background ?? AnyShapeStyle(Color.controlBackground)))
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .padding(40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        case .alert, .confirmationDialog:
            ZStack {
                Color.black.opacity(0.2)
                _PresentationContent(entry: entry)
                    .padding(20)
                    .frame(width: 280)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.controlBackground))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        case .popover, .menu:
            _AnchoredLayout(anchor: anchor ?? .zero, gap: entry.kind == .menu ? 2 : 8) {
                Color.clear.contentShape(Rectangle()).onTapGesture { entry.interactiveDismiss() }
                _PresentationContent(entry: entry)
                    .padding(entry.kind == .menu ? 4 : 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.controlBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.separator))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
        }
    }
}

extension _PresentationChrome: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: _PresentationChrome, _ rhs: _PresentationChrome) -> Bool {
        MainActor.assumeIsolated { lhs.entry === rhs.entry && lhs.anchor == rhs.anchor }
    }
}

/// Fills the layer with the first subview (backdrop) and places the second below (or above) the
/// anchor rectangle, clamped to the layer bounds.
struct _AnchoredLayout: Layout, Equatable {
    let anchor: CGRect
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 400))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        let size = subviews[1].sizeThatFits(ProposedViewSize(width: min(bounds.width - 16, 420), height: nil))
        var x = anchor.midX - size.width / 2
        if size.width < anchor.width + 40 { x = anchor.minX }
        x = min(max(bounds.minX + 8, x), bounds.maxX - size.width - 8)
        var y = anchor.maxY + gap
        if y + size.height > bounds.maxY - 8, anchor.minY - gap - size.height > bounds.minY { y = anchor.minY - gap - size.height }
        subviews[1].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
    }
}

// MARK: - Presentation modifiers

public struct _SheetModifier<SheetContent: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let content: () -> SheetContent
    let kind: PresentationEntry.Kind
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let outputs = body(inputs)
        let source = modifier.attribute
        let kind = AnyAttribute.withoutDependencies { source.value.kind }
        inputs.makePresentation(
            kind: kind,
            isPresented: { source.value.isPresented.wrappedValue },
            setPresented: { value in AnyAttribute.withoutDependencies { source.value.isPresented.wrappedValue = value } },
            onDismiss: { AnyAttribute.withoutDependencies { source.peekValue?.onDismiss?() } }
        ) { inputs in
            let content = Attribute<SheetContent>(inputs.subgraph)
            content.setRule { [unowned content] in
                let builder = source.value.content
                return observingChanges(invalidating: content) { builder() }
            }
            return SheetContent._makeView(view: _GraphValue(content), inputs: inputs)
        }
        return outputs
    }
}

extension View {
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: onDismiss, content: content, kind: .sheet))
    }

    public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(_SheetModifier(isPresented: presented, onDismiss: onDismiss, content: {
            Group { if let value = item.wrappedValue { content(value) } }
        }, kind: .sheet))
    }

    public func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    public func popover<Content: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: content, kind: .popover))
    }

    public func popover<Item: Identifiable, Content: View>(item: Binding<Item?>, attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge = .top, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        let presented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(_SheetModifier(isPresented: presented, onDismiss: nil, content: {
            Group { if let value = item.wrappedValue { content(value) } }
        }, kind: .popover))
    }

    public func alert<A: View>(_ title: Text, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: title, message: nil, actions: AnyView(actions()), vertical: false)
        }, kind: .alert))
    }

    public func alert<A: View, M: View>(_ title: Text, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: title, message: AnyView(message()), actions: AnyView(actions()), vertical: false)
        }, kind: .alert))
    }

    public func alert<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions)
    }

    public func alert<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        alert(Text(title), isPresented: isPresented, actions: actions, message: message)
    }

    public func alert<S: StringProtocol, A: View, M: View, T>(_ title: S, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: Text(title), message: data.map { AnyView(message($0)) }, actions: AnyView(Group { if let data { actions(data) } }), vertical: false)
        }, kind: .alert))
    }

    public func confirmationDialog<S: StringProtocol, A: View>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: Text(title), message: nil, actions: AnyView(Group {
                actions()
                Button("Cancel", role: .cancel) {}
            }), vertical: true)
        }, kind: .confirmationDialog))
    }

    public func confirmationDialog<S: StringProtocol, A: View, M: View>(_ title: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        modifier(_SheetModifier(isPresented: isPresented, onDismiss: nil, content: {
            _DialogContent(title: Text(title), message: AnyView(message()), actions: AnyView(Group {
                actions()
                Button("Cancel", role: .cancel) {}
            }), vertical: true)
        }, kind: .confirmationDialog))
    }

    public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View { self }
    public func presentationDragIndicator(_ visibility: Visibility) -> some View { self }
}

public enum Visibility: Hashable, Sendable { case automatic, visible, hidden }
public struct PresentationDetent: Hashable, Sendable {
    let id: String
    public static let medium = PresentationDetent(id: "medium")
    public static let large = PresentationDetent(id: "large")
    public static func height(_ height: CGFloat) -> PresentationDetent { PresentationDetent(id: "h\(height)") }
    public static func fraction(_ fraction: CGFloat) -> PresentationDetent { PresentationDetent(id: "f\(fraction)") }
}

public enum PopoverAttachmentAnchor: Sendable {
    case rect(Anchor<CGRect>.Source)
    case point(UnitPoint)
}

extension Anchor.Source: @unchecked Sendable {}

struct _DialogContent: View {
    let title: Text
    let message: AnyView?
    let actions: AnyView
    let vertical: Bool
    @Environment(\.dialogIcon) private var icon
    @Environment(\.dialogSeverity) private var severity
    @Environment(\.dialogSuppression) private var suppression

    var body: some View {
        VStack(spacing: 12) {
            if icon != nil || severity == .critical {
                ZStack(alignment: .bottomTrailing) {
                    (icon ?? Image(systemName: "app.dashed")).resizable().scaledToFit().frame(width: 56, height: 56)
                    if severity == .critical {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Color.yellow)
                    }
                }
            }
            title.font(.headline).multilineTextAlignment(.center)
            if let message {
                message.font(.callout).multilineTextAlignment(.center)
            }
            if let suppression {
                Toggle(isOn: suppression.binding) { suppression.label.font(.callout) }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if vertical {
                VStack(spacing: 6) { actions }.buttonStyle(.bordered).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) { actions }
            }
        }
    }
}

// MARK: - Menu

public struct Menu<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let primaryAction: (@MainActor () -> Void)?
    @State private var isPresented = false
    @Environment(\.menuIsBorderless) private var isBorderless
    @Environment(\.menuIndicatorVisibility) private var indicator
    @Environment(\.buttonStyle) private var buttonStyle
    @Environment(\.customButtonStyle) private var customStyle
    @Environment(\.customMenuStyle) private var customMenuStyle
    /// Menus created from a style configuration render natively (not through the style again).
    var fromConfiguration = false

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
        self.primaryAction = nil
    }

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label, primaryAction: @escaping @MainActor () -> Void) {
        self.content = content()
        self.label = label()
        self.primaryAction = primaryAction
    }

    public var body: some View {
        if !fromConfiguration, let customMenuStyle {
            customMenuStyle.make(MenuStyleConfiguration(label: _StyleContent(label), content: _StyleContent(content)))
        } else {
            nativeMenu
        }
    }

    private var nativeMenu: some View {
        Button {
            if let primaryAction { primaryAction() } else { isPresented = true }
        } label: {
            menuLabel
        }
        .modifier(_OptionalBorderless(isBorderless: isBorderless && customStyle == nil && buttonStyle != .plain))
        .modifier(_SheetModifier(isPresented: $isPresented, onDismiss: nil, content: {
            _MenuItems(content: content)
        }, kind: .menu))
    }

    /// macOS SwiftUI: with a plain or custom button style the menu is just its label, drawn by that
    /// style; borderless buttons add the indicator; otherwise it is a pull-down button showing the
    /// label's title and symbol, filling the proposed width (its label's own layout is ignored).
    @ViewBuilder private var menuLabel: some View {
        if customStyle != nil || buttonStyle == .plain {
            label
        } else if buttonStyle == .borderless && !isBorderless {
            // Unlike borderless buttons, the menu's label keeps the primary color.
            HStack(spacing: 9) {
                label
                if indicator != .hidden { _MenuIndicator() }
            }
            .foregroundStyle(.primary)
        } else {
            let (title, symbol) = MenuItems.title(of: label)
            HStack(spacing: 0) {
                if let symbol {
                    SwiftUI2Core.Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
                Spacer(minLength: 6.5)
                if indicator != .hidden { _MenuIndicator() }
            }
            .lineLimit(1)
        }
    }
}

struct _MenuIndicator: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
    }
}

extension Menu where Label == MenuStyleConfiguration.Label, Content == MenuStyleConfiguration.Content {
    /// A native menu from a style configuration (inside custom menu styles).
    public init(_ configuration: MenuStyleConfiguration) {
        self.init(content: { configuration.content }, label: { configuration.label })
        self.fromConfiguration = true
    }
}

extension EnvironmentValues {
    var customMenuStyle: _AnyStyle<MenuStyleConfiguration>? { self[style: MenuStyleConfiguration.self] }
}

extension Menu where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

extension Menu where Label == SwiftUI2Core.Label<Text, Image> {
    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }
}

struct _MenuItems<Content: View>: View {
    let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .buttonStyle(_MenuItemButtonStyle())
            .frame(minWidth: 140, alignment: .leading)
    }
}

struct _MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? Color.accentColor : Color.clear))
            .foregroundStyle(configuration.isPressed ? Color.white : Color.primary)
    }
}

public struct _ContextMenuModifier<MenuContent: View>: ViewModifier {
    let menu: () -> MenuContent
    @State private var isPresented = false

    public func body(content: Content) -> some View {
        content
            .modifier(_SecondaryClickModifier { isPresented = true })
            .modifier(_SheetModifier(isPresented: $isPresented, onDismiss: nil, content: { _MenuItems(content: menu()) }, kind: .menu))
    }
}

struct _SecondaryClickModifier: PlatformEffectModifier {
    let action: @MainActor () -> Void
    static var pathComponent: String { "contextMenu" }
    func effect(size: CGSize) -> DisplayEffect { .opacity(1) }
    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.secondaryClick = { [weak modifier] in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.action() }
        }
        return actions
    }
}

extension View {
    public func contextMenu<M: View>(@ViewBuilder menuItems: @escaping () -> M) -> some View {
        modifier(_ContextMenuModifier(menu: menuItems))
    }
}

/// `.menuStyle(.borderlessButton)`: the menu's button has no bezel.
struct _OptionalBorderless: ViewModifier {
    let isBorderless: Bool
    func body(content: Content) -> some View {
        if isBorderless { content.buttonStyle(.borderless) } else { content }
    }
}

// MARK: - Legacy Alert / ActionSheet values

/// Mirrors the pre-iOS 15 `Alert` value (shown with the modern alert presentation).
public struct Alert {
    public struct Button {
        enum Role { case `default`, cancel, destructive }
        let label: Text
        let role: Role
        let action: (@MainActor () -> Void)?

        public static func `default`(_ label: Text, action: (@MainActor () -> Void)? = {}) -> Button { Button(label: label, role: .default, action: action) }
        public static func cancel(_ label: Text, action: (@MainActor () -> Void)? = {}) -> Button { Button(label: label, role: .cancel, action: action) }
        public static func cancel(_ action: (@MainActor () -> Void)? = {}) -> Button { Button(label: Text("Cancel"), role: .cancel, action: action) }
        public static func destructive(_ label: Text, action: (@MainActor () -> Void)? = {}) -> Button { Button(label: label, role: .destructive, action: action) }
    }

    let title: Text
    let message: Text?
    let buttons: [Button]

    public init(title: Text, message: Text? = nil, dismissButton: Button? = nil) {
        self.title = title
        self.message = message
        self.buttons = [dismissButton ?? .default(Text("OK"))]
    }

    public init(title: Text, message: Text? = nil, primaryButton: Button, secondaryButton: Button) {
        self.title = title
        self.message = message
        self.buttons = [primaryButton, secondaryButton]
    }

    @MainActor @ViewBuilder var actions: some View {
        ForEach(buttons.indices, id: \.self) { index in
            let button = buttons[index]
            SwiftUI2Core.Button(role: button.role == .cancel ? .cancel : button.role == .destructive ? .destructive : nil) {
                button.action?()
            } label: {
                button.label
            }
        }
    }
}

public struct ActionSheet {
    let alert: Alert
    public init(title: Text, message: Text? = nil, buttons: [Alert.Button] = [.cancel()]) {
        var alert = Alert(title: title, message: message)
        alert = Alert(title: title, message: message, buttons: buttons)
        self.alert = alert
    }
}

extension Alert {
    init(title: Text, message: Text?, buttons: [Button]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

extension View {
    public func alert(isPresented: Binding<Bool>, content: () -> Alert) -> some View {
        let alert = content()
        return self.alert(alert.title, isPresented: isPresented) {
            alert.actions
        } message: {
            if let message = alert.message { message }
        }
    }

    public func alert<Item: Identifiable>(item: Binding<Item?>, content: @escaping (Item) -> Alert) -> some View {
        let isPresented = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        let alert = item.wrappedValue.map(content)
        return self.alert(alert?.title ?? Text(""), isPresented: isPresented) {
            if let alert { alert.actions }
        } message: {
            if let message = alert?.message { message }
        }
    }

    public func actionSheet(isPresented: Binding<Bool>, content: () -> ActionSheet) -> some View {
        alert(isPresented: isPresented) { content().alert }
    }
}
