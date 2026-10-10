import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Button styles

public enum ButtonStyleKind: Hashable, Sendable { case automatic, bordered, borderedProminent, borderless, plain, link }
public enum ToggleStyleKind: Hashable, Sendable { case automatic, checkbox, `switch`, button }
public enum ButtonRole: Hashable, Sendable { case cancel, destructive }

public struct ButtonStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: some View { content }
    }

    public let role: ButtonRole?
    public let label: Label
    public let isPressed: Bool
}

public struct PrimitiveButtonStyleConfiguration {
    public typealias Label = ButtonStyleConfiguration.Label
    public let role: ButtonRole?
    public let label: Label
    let action: @MainActor () -> Void
    @MainActor public func trigger() { action() }
}

/// A style that customizes a button's appearance; the system handles the interaction.
@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    typealias Configuration = ButtonStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// A style that customizes appearance *and* interaction (calls `configuration.trigger()`).
@MainActor @preconcurrency
public protocol PrimitiveButtonStyle {
    associatedtype Body: View
    typealias Configuration = PrimitiveButtonStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    var _builtinKind: ButtonStyleKind? { get }
}

extension PrimitiveButtonStyle {
    public var _builtinKind: ButtonStyleKind? { nil }
}

public struct DefaultButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .automatic }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderedButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .bordered }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .borderedProminent }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct BorderlessButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .borderless }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct PlainButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .plain }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct LinkButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public var _builtinKind: ButtonStyleKind? { .link }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle { public static var automatic: DefaultButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: BorderedButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: BorderedProminentButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: BorderlessButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { .init() } }
extension PrimitiveButtonStyle where Self == LinkButtonStyle { public static var link: LinkButtonStyle { .init() } }

/// Type-erased custom button style stored in the environment.
@MainActor
struct AnyButtonStyleBox {
    let make: @MainActor (_ action: @escaping @MainActor () -> Void, _ label: AnyView, _ role: ButtonRole?) -> AnyView
    let identity: ObjectIdentifier
}

struct CustomButtonStyleKey: EnvironmentKey { static let defaultValue: AnyButtonStyleBox? = nil }

extension AnyButtonStyleBox: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: AnyButtonStyleBox, _ rhs: AnyButtonStyleBox) -> Bool {
        lhs.identity == rhs.identity
    }
}

extension EnvironmentValues {
    var customButtonStyle: AnyButtonStyleBox? {
        get { self[CustomButtonStyleKey.self] }
        set { self[CustomButtonStyleKey.self] = newValue }
    }
}

extension View {
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        transformEnvironment(\.self) { environment in
            if let kind = style._builtinKind {
                environment.buttonStyle = kind
                environment.customButtonStyle = nil
            } else {
                environment.customButtonStyle = AnyButtonStyleBox(make: { action, label, role in
                    AnyView(style.makeBody(configuration: PrimitiveButtonStyleConfiguration(role: role, label: .init(content: label), action: action)))
                }, identity: ObjectIdentifier(S.self))
            }
        }
    }

    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        environment(\.customButtonStyle, AnyButtonStyleBox(make: { action, label, role in
            AnyView(_PressableButton(style: style, action: action, label: label, role: role))
        }, identity: ObjectIdentifier(S.self)))
    }
}

/// Custom `ButtonStyle` host: tracks press state and triggers the action.
struct _PressableButton<S: ButtonStyle>: View {
    let style: S
    let action: @MainActor () -> Void
    let label: AnyView
    let role: ButtonRole?
    @State private var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonDismissAction) private var dismissAfterAction

    var body: some View {
        style.makeBody(configuration: ButtonStyleConfiguration(role: role, label: .init(content: label), isPressed: isPressed))
            .modifier(_PressModifier(isPressed: $isPressed, action: {
                guard isEnabled else { return }
                action()
                dismissAfterAction?()
            }))
    }
}

struct _PressModifier: PlatformEffectModifier {
    let isPressed: Binding<Bool>
    let action: @MainActor () -> Void
    static var pathComponent: String { "pressable" }
    func effect(size: CGSize) -> DisplayEffect { .tapTarget }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.primary = { [weak modifier] in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.action() }
        }
        actions.pressed = { [weak modifier] pressed in
            guard let modifier else { return }
            AnyAttribute.withoutDependencies { modifier.value.isPressed.wrappedValue = pressed }
        }
        return actions
    }
}

// MARK: - Button

public struct Button<Label: View>: View {
    let action: @MainActor () -> Void
    let label: Label
    let role: ButtonRole?
    @Environment(\.customButtonStyle) private var customStyle

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.role = nil
    }

    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.role = role
    }

    public var body: some View {
        if let customStyle {
            customStyle.make(action, AnyView(label), role)
        } else {
            _PlatformButton(action: action, label: label, role: role)
        }
    }
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(titleKey) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(titleKey) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension Button where Label == SwiftUI2Core.Label<Text, Image> {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }
}

/// The platform push button (bezel + label children).
public struct _PlatformButton<Label: View>: View {
    let action: @MainActor () -> Void
    let label: Label
    let role: ButtonRole?

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Button")
        let environment = inputs.environment
        let style = Attribute<ButtonStyleKind>(inputs.subgraph, isEqual: { $0 == $1 }) { environment.value.buttonStyle }
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let env = environment.value
            let isDestructive = view.attribute.value.role == .destructive
            let tint = isDestructive ? Color.red.resolve(in: env) : env.tint?.resolve(in: env)
            // In inactive windows, accent-colored prominent buttons draw as plain bordered ones.
            var drawnStyle = style.value
            if drawnStyle == .borderedProminent, tint == nil, !env.appearsActive { drawnStyle = .bordered }
            return .button(ResolvedButton(style: drawnStyle, isEnabled: env.isEnabled && env.allowsHitTesting, tint: tint, repeats: env._buttonRepeats, borderShape: env.buttonBorderShape))
        }
        var actions = RenderActions()
        let viewAttribute = view.attribute
        actions.primary = { [weak viewAttribute] in
            guard let viewAttribute else { return }
            let env = AnyAttribute.withoutDependencies { environment.value }
            guard env.isEnabled, env.allowsHitTesting else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.action() }
            env.buttonDismissAction?()
        }
        actions.keyboardShortcut = AnyAttribute.withoutDependencies { environment.value.keyboardShortcut }
        let render = inputs.makePlatformNode(content: content, actions: actions)
        let services = inputs.services
        let tracer = inputs.tracer
        let geometry = inputs.geometry

        let labelGeometry = inputs.makeChildGeometry()
        var labelInputs = inputs.child(geometry: labelGeometry, render: render)
        labelInputs.stackAxis = nil
        labelInputs.environment = Attribute<EnvironmentValues>(inputs.subgraph) {
            var env = environment.value
            let role = viewAttribute.value.role
            switch env.buttonStyle {
            case .borderedProminent:
                if env.appearsActive || env.tint != nil || role == .destructive { env.foregroundStyle = AnyShapeStyle(Color.white) }
            case .link: env.foregroundStyle = AnyShapeStyle(env.tint ?? .link)
            case .borderless:
                if env.foregroundStyle == nil, role != .destructive { env.foregroundStyle = AnyShapeStyle(env.tint ?? .accentColor) }
            default: break
            }
            if role == .destructive, env.buttonStyle != .borderedProminent {
                env.foregroundStyle = AnyShapeStyle(Color.red)
            }
            if env.font == nil, let font = Font.controlFont(env.controlSize) { env.font = font }
            return env
        }
        let label = Label._makeView(view: view.project(inputs) { $0.label }, inputs: labelInputs)
        let labelLayout = label.layout
        let path = inputs.path
        let controlSize = Attribute<ControlSize>(inputs.subgraph, isEqual: { $0 == $1 }) { environment.value.controlSize }
        let inForm = Attribute<Bool>(inputs.subgraph, isEqual: { $0 == $1 }) { environment.value.isInForm }
        let shapeAndSizing = Attribute<(Bool, Bool)>(inputs.subgraph, isEqual: { $0 == $1 }) {
            (environment.value.buttonBorderShape == .circle, environment.value._buttonSizing == .flexible)
        }
        let layout = inputs.makeLayoutAttribute {
            let computer = ButtonComputer(metrics: services.controlMetrics(.button(style.value)).scaled(for: controlSize.value, inForm: inForm.value), child: labelLayout.value, path: path, tracer: tracer)
            (computer.isCircle, computer.isFlexible) = shapeAndSizing.value
            return computer
        }
        labelGeometry.setRule {
            (layout.value as! ButtonComputer).placeChild(in: geometry.value, child: labelLayout.value)
        }
        return _ViewOutputs(layout: layout, preferences: label.preferences)
    }
}

extension ControlMetrics {
    /// Bordered controls at a control size, measured on macOS SwiftUI.
    /// Modern design: mini 13pt tall with 8pt insets, small 20/10, regular 24/12, large 28/14,
    /// extra large 36/18. Classic: mini 13/5, small 16/6, regular 20/8, large 28/8 (extra large
    /// like regular). Grouped form rows use 20/8 buttons in both.
    func scaled(for size: ControlSize, inForm: Bool = false) -> ControlMetrics {
        guard minSize.height > 0 else { return self }
        var copy = self
        func set(_ height: CGFloat, _ inset: CGFloat) {
            copy.minSize.height = height
            let vertical = max(0, (height - 16) / 2)
            copy.contentInsets = EdgeInsets(top: vertical, leading: inset, bottom: vertical, trailing: inset)
        }
        if design == .modern {
            switch size {
            case .mini: set(13, 8)
            case .small: set(20, 10)
            case .regular: break
            case .large: set(28, 14)
            case .extraLarge: set(36, 18)
            }
        } else {
            switch size {
            case .mini: copy.minSize.height = 13; copy.contentInsets = EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5)
            case .small: copy.minSize.height = 16; copy.contentInsets = EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
            case .large: copy.minSize.height = 28; copy.contentInsets = EdgeInsets(top: 6, leading: contentInsets.leading, bottom: 6, trailing: contentInsets.trailing)
            case .regular, .extraLarge: break
            }
        }
        return copy
    }
}

extension Font {
    /// The label font of controls at a control size when no font is set (`nil`: the default font).
    static func controlFont(_ size: ControlSize) -> Font? {
        switch size {
        case .mini: .system(size: 9)
        case .small: .system(size: 11)
        default: nil
        }
    }
}

final class ButtonComputer: UnaryLayoutComputer {
    let metrics: ControlMetrics
    /// Circular bezels are square; flexible buttons take the proposed width.
    var isCircle = false
    var isFlexible = false

    init(metrics: ControlMetrics, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.metrics = metrics
        super.init(child: child, path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let insets = metrics.contentInsets
        let inner = ProposedViewSize(
            width: proposal.width.map { max(0, $0 - insets.horizontal) },
            height: proposal.height.map { max(0, $0 - insets.vertical) }
        )
        let label = child.sizeThatFits(inner)
        var size = CGSize(
            width: max(metrics.minSize.width, label.width + insets.horizontal),
            height: max(metrics.minSize.height, label.height + insets.vertical)
        )
        if isCircle, metrics.minSize.height > 0 {
            let side = max(size.height, label.width + insets.vertical)
            size = CGSize(width: side, height: side)
        }
        if isFlexible, let width = proposal.width, width.isFinite { size.width = max(size.width, width) }
        return size
    }

    /// Bezel-less buttons (no metrics) space like their label; bordered ones like controls.
    override var spacing: ViewSpacing { metrics.minSize.height == 0 && metrics.contentInsets == EdgeInsets() ? child.spacing : .default }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        guard key.axis == .vertical else { return nil }
        let inner = CGSize(width: max(0, size.width - metrics.contentInsets.horizontal), height: max(0, size.height - metrics.contentInsets.vertical))
        let labelSize = child.sizeThatFits(ProposedViewSize(inner))
        let top = metrics.contentInsets.top + (inner.height - labelSize.height) / 2
        return child.explicitAlignment(key, in: labelSize).map { $0 + top }
    }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let insets = metrics.contentInsets
        let inner = CGSize(width: max(0, geometry.size.width - insets.horizontal), height: max(0, geometry.size.height - insets.vertical))
        let size = child.sizeThatFits(ProposedViewSize(inner))
        let innerGeometry = ViewGeometry(origin: CGPoint(x: geometry.origin.x + insets.leading, y: geometry.origin.y + insets.top), size: inner, proposal: ProposedViewSize(inner))
        return innerGeometry.aligning(childSize: size, child: child, container: dimensions(size: inner), alignment: .center, proposal: ProposedViewSize(inner))
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool { (other as? ButtonComputer)?.metrics == metrics }
}

// MARK: - Toggle

public struct ToggleStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: some View { content }
    }

    public let label: Label
    @Binding public var isOn: Bool
    public var isMixed = false
}

@MainActor @preconcurrency
public protocol ToggleStyle {
    associatedtype Body: View
    typealias Configuration = ToggleStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    var _builtinKind: ToggleStyleKind? { get }
}

extension ToggleStyle {
    public var _builtinKind: ToggleStyleKind? { nil }
}

public struct DefaultToggleStyle: ToggleStyle {
    public init() {}
    public var _builtinKind: ToggleStyleKind? { .automatic }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct SwitchToggleStyle: ToggleStyle {
    public init() {}
    public var _builtinKind: ToggleStyleKind? { .switch }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct CheckboxToggleStyle: ToggleStyle {
    public init() {}
    public var _builtinKind: ToggleStyleKind? { .checkbox }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

public struct ButtonToggleStyle: ToggleStyle {
    public init() {}
    public var _builtinKind: ToggleStyleKind? { .button }
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
}

extension ToggleStyle where Self == DefaultToggleStyle { public static var automatic: DefaultToggleStyle { .init() } }
extension ToggleStyle where Self == SwitchToggleStyle { public static var `switch`: SwitchToggleStyle { .init() } }
extension ToggleStyle where Self == CheckboxToggleStyle { public static var checkbox: CheckboxToggleStyle { .init() } }
extension ToggleStyle where Self == ButtonToggleStyle { public static var button: ButtonToggleStyle { .init() } }

@MainActor
struct AnyToggleStyleBox {
    let make: @MainActor (ToggleStyleConfiguration) -> AnyView
    let identity: ObjectIdentifier
}

extension AnyToggleStyleBox: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: AnyToggleStyleBox, _ rhs: AnyToggleStyleBox) -> Bool { lhs.identity == rhs.identity }
}

struct CustomToggleStyleKey: EnvironmentKey { static let defaultValue: AnyToggleStyleBox? = nil }

extension EnvironmentValues {
    var customToggleStyle: AnyToggleStyleBox? {
        get { self[CustomToggleStyleKey.self] }
        set { self[CustomToggleStyleKey.self] = newValue }
    }
}

extension View {
    public func toggleStyle<S: ToggleStyle>(_ style: S) -> some View {
        transformEnvironment(\.self) { environment in
            if let kind = style._builtinKind {
                environment.toggleStyle = kind
                environment.customToggleStyle = nil
            } else {
                environment.customToggleStyle = AnyToggleStyleBox(make: { AnyView(style.makeBody(configuration: $0)) }, identity: ObjectIdentifier(S.self))
            }
        }
    }
}

public struct Toggle<Label: View>: View {
    let isOn: Binding<Bool>
    let label: Label
    /// `sources:` toggles: some but not all sources are on.
    var isMixed: (() -> Bool)? = nil
    @Environment(\.customToggleStyle) private var customStyle
    @Environment(\.toggleStyle) private var kind
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm
    @Environment(\.controlSize) private var controlSize
    @Environment(\.font) private var font

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    /// One toggle for several values: on when all are on, mixed when some are; setting it sets all.
    public init<C: RandomAccessCollection>(sources: C, isOn: KeyPath<C.Element, Binding<Bool>>, @ViewBuilder label: () -> Label) {
        let bindings = sources.map { $0[keyPath: isOn] }
        self.isOn = Binding(get: { !bindings.isEmpty && bindings.allSatisfy(\.wrappedValue) }, set: { value in bindings.forEach { $0.wrappedValue = value } })
        self.label = label()
        self.isMixed = { bindings.contains(where: \.wrappedValue) && !bindings.allSatisfy(\.wrappedValue) }
    }

    public var body: some View {
        if let customStyle {
            customStyle.make(ToggleStyleConfiguration(label: .init(content: AnyView(label)), isOn: isOn, isMixed: isMixed?() ?? false))
        } else if kind == .button {
            Button { isOn.wrappedValue.toggle() } label: { label }
                .environment(\.buttonStyle, isOn.wrappedValue ? .borderedProminent : .bordered)
        } else if isInForm && (kind == .switch || kind == .automatic) {
            // Grouped form row: a mini switch trailing.
            if labelsHidden {
                _ToggleControl(isOn: isOn).environment(\.toggleStyle, .switch).controlSize(.mini)
            } else {
                _FormLabeledRow { label } control: {
                    _ToggleControl(isOn: isOn).environment(\.toggleStyle, .switch).controlSize(.mini)
                }
            }
        } else if kind == .switch {
            // Outside forms a switch hugs its label (measured on macOS SwiftUI).
            HStack(spacing: 8) {
                if !labelsHidden { label }
                _ToggleControl(isOn: isOn)
            }
        } else {
            HStack(spacing: controlSize == .small || controlSize == .mini ? 4 : 5) {
                _ToggleControl(isOn: isOn, isMixed: isMixed?() ?? false)
                if !labelsHidden { label.font(font ?? Font.controlFont(controlSize)) }
            }
        }
    }
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(titleKey) }
    }

    public init<C: RandomAccessCollection>(_ titleKey: LocalizedStringKey, sources: C, isOn: KeyPath<C.Element, Binding<Bool>>) {
        self.init(sources: sources, isOn: isOn) { Text(titleKey) }
    }

    @_disfavoredOverload public init<S: StringProtocol, C: RandomAccessCollection>(_ title: S, sources: C, isOn: KeyPath<C.Element, Binding<Bool>>) {
        self.init(sources: sources, isOn: isOn) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

extension Toggle where Label == SwiftUI2Core.Label<Text, Image> {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }
}

/// The platform checkbox / switch.
public struct _ToggleControl: View {
    let isOn: Binding<Bool>
    var isMixed = false
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "ToggleControl")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let env = environment.value
            let style: ToggleStyleKind = env.toggleStyle == .switch ? .switch : .checkbox
            let control = view.attribute.value
            return .toggle(ResolvedToggle(isOn: control.isOn.wrappedValue, style: style, isEnabled: env.isEnabled, isMixed: control.isMixed, controlSize: env.controlSize))
        }
        let viewAttribute = view.attribute
        var actions = RenderActions()
        actions.setBool = { [weak viewAttribute] value in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.isOn.wrappedValue = value }
        }
        inputs.makePlatformNode(content: content, actions: actions)
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        let layout = inputs.makeLayoutAttribute {
            let env = environment.value
            let kind: ControlKind = env.toggleStyle == .switch ? .switch : .checkbox
            var size = services.controlMetrics(kind).minSize
            if kind == .checkbox, env.controlSize == .small || env.controlSize == .mini {
                size = CGSize(width: max(0, size.width - 2), height: max(0, size.height - 2))
            }
            // Mini switches (grouped forms) are 26 × 16, as SwiftUI draws them.
            if kind == .switch, env.controlSize == .mini { size = CGSize(width: 26, height: env._controlDesign == .modern ? 16.5 : 16) }
            return FixedLayoutComputer(size: size, path: path, tracer: tracer)
        }
        return _ViewOutputs(layout: layout)
    }
}

final class FixedLayoutComputer: LayoutComputer {
    let size: CGSize
    init(size: CGSize, path: ViewPath, tracer: UpdateTracer) {
        self.size = size
        super.init(path: path, tracer: tracer)
    }
    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { size }
    override func isEquivalent(to other: LayoutComputer) -> Bool { (other as? FixedLayoutComputer)?.size == size }
}

/// Fixed height; width takes the proposal (ideal width when unspecified). Multi-line editors take
/// the proposal in both axes.
final class ControlLayoutComputer: LayoutComputer {
    let metrics: ControlMetrics
    let flexibleHeight: Bool
    init(metrics: ControlMetrics, flexibleHeight: Bool = false, path: ViewPath, tracer: UpdateTracer) {
        self.metrics = metrics
        self.flexibleHeight = flexibleHeight
        super.init(path: path, tracer: tracer)
    }
    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        var width = max(metrics.minSize.width, proposal.width ?? metrics.idealWidth)
        if !width.isFinite { width = metrics.idealWidth }
        var height = flexibleHeight ? max(metrics.minSize.height, proposal.height ?? metrics.minSize.height) : metrics.minSize.height
        if !height.isFinite { height = metrics.minSize.height }
        return CGSize(width: width, height: height)
    }
    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? ControlLayoutComputer else { return false }
        return other.metrics == metrics && other.flexibleHeight == flexibleHeight
    }
}

// MARK: - Text fields

public enum TextFieldStyleKind: Hashable, Sendable { case automatic, roundedBorder, plain, squareBorder }

@MainActor @preconcurrency public protocol TextFieldStyle {}
public struct DefaultTextFieldStyle: TextFieldStyle { public init() {} }
public struct RoundedBorderTextFieldStyle: TextFieldStyle { public init() {} }
public struct PlainTextFieldStyle: TextFieldStyle { public init() {} }
public struct SquareBorderTextFieldStyle: TextFieldStyle { public init() {} }
extension TextFieldStyle where Self == DefaultTextFieldStyle { public static var automatic: DefaultTextFieldStyle { .init() } }
extension TextFieldStyle where Self == RoundedBorderTextFieldStyle { public static var roundedBorder: RoundedBorderTextFieldStyle { .init() } }
extension TextFieldStyle where Self == PlainTextFieldStyle { public static var plain: PlainTextFieldStyle { .init() } }
extension TextFieldStyle where Self == SquareBorderTextFieldStyle { public static var squareBorder: SquareBorderTextFieldStyle { .init() } }

extension View {
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        let kind: TextFieldStyleKind
        switch style {
        case is RoundedBorderTextFieldStyle: kind = .roundedBorder
        case is PlainTextFieldStyle: kind = .plain
        case is SquareBorderTextFieldStyle: kind = .squareBorder
        default: kind = .automatic
        }
        return environment(\.textFieldStyle, kind)
    }
}

/// Shared platform text input (single line, secure or multi-line).
struct _TextInput: View {
    enum Kind: Hashable { case field, secure, editor, verticalField }
    let text: Binding<String>
    let prompt: String
    let kind: Kind

    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let kind = AnyAttribute.withoutDependencies { view.attribute.value.kind }
        let inputs = inputs.with(path: kind == .editor ? "TextEditor" : kind == .secure ? "SecureField" : "TextField")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let env = environment.value
            let field = view.attribute.value
            return .textField(ResolvedTextField(
                text: field.text.wrappedValue, placeholder: field.prompt, isEnabled: env.isEnabled,
                font: (env.font ?? .body).resolve(), isSecure: field.kind == .secure, isMultiline: field.kind == .editor,
                style: field.kind == .editor ? (env.textEditorStyle == .plain ? .plain : .automatic) : env.textFieldStyle, wantsFocus: env.focusRequest?.isFocused() ?? false,
                color: ForegroundStyle()._resolveColor(in: env), wraps: field.kind == .verticalField,
                isFindEnabled: !env.findDisabled, showsFindNavigator: env.findNavigatorPresented?.wrappedValue ?? false,
                isAutocorrectionDisabled: env.autocorrectionDisabled, contentType: env._textContentType,
                writingTools: env.writingToolsBehavior, showsFormattingControls: env.textInputFormattingControlVisibility == .visible,
                alignment: env.multilineTextAlignment
            ))
        }
        let viewAttribute = view.attribute
        var actions = RenderActions()
        actions.setText = { [weak viewAttribute] value in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.text.wrappedValue = value }
        }
        actions.submit = {
            AnyAttribute.withoutDependencies { environment.value.submitAction?() }
        }
        actions.focusChanged = { focused in
            AnyAttribute.withoutDependencies { environment.value.focusRequest?.setFocused(focused) }
        }
        inputs.makePlatformNode(content: content, actions: actions)
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute {
            let env = environment.value
            var metrics = services.controlMetrics(.textField(env.textFieldStyle))
            let font = (env.font ?? .body).resolve()
            let black = Color.Resolved(red: 0, green: 0, blue: 0, opacity: 1)
            let line = ResolvedText(string: "X", font: font, color: black, lineLimit: 1, alignment: .leading, strikethrough: false, underline: false)
            let lineHeight = services.measureText(line, proposal: .unspecified).height
            if kind == .verticalField {
                // The rendered content carries the (observed) current text.
                guard case .textField(let field) = content.value else { return ControlLayoutComputer(metrics: metrics, path: path, tracer: tracer) }
                let text = ResolvedText(string: field.text.isEmpty ? field.placeholder : field.text, font: font, color: black, lineLimit: env.lineLimit, alignment: .leading, strikethrough: false, underline: false)
                return VerticalTextFieldLayoutComputer(
                    metrics: metrics, text: text, lineHeight: lineHeight,
                    minimumLines: env.minimumLineLimit ?? 1, services: services, path: path, tracer: tracer)
            }
            if kind == .editor {
                metrics.minSize.height = 40
                return ControlLayoutComputer(metrics: metrics, flexibleHeight: true, path: path, tracer: tracer)
            }
            // macOS SwiftUI: one text line plus the style's insets (rounded borders are a fixed
            // 22pt); the ideal width is the prompt's plus the insets, whole points when bezeled.
            metrics.minSize.height = metrics.fixedHeight ?? max(metrics.minSize.height, lineHeight + metrics.contentInsets.vertical)
            let prompt = view.attribute.value.prompt
            if kind == .secure {
                metrics.idealWidth = 0
            } else if !prompt.isEmpty {
                let promptText = ResolvedText(string: prompt, font: font, color: black, lineLimit: 1, alignment: .leading, strikethrough: false, underline: false)
                let width = services.unroundedTextWidth(promptText) + metrics.contentInsets.horizontal
                let bezeled = env.textFieldStyle == .automatic || env.textFieldStyle == .squareBorder
                metrics.idealWidth = bezeled ? width.rounded() : width
            }
            return ControlLayoutComputer(metrics: metrics, path: path, tracer: tracer)
        })
    }
}

/// A text field that wraps and grows vertically, between the `lineLimit` range bounds.
final class VerticalTextFieldLayoutComputer: LayoutComputer {
    let metrics: ControlMetrics
    let text: ResolvedText
    let lineHeight: CGFloat
    let minimumLines: Int
    let services: PlatformServices
    init(metrics: ControlMetrics, text: ResolvedText, lineHeight: CGFloat, minimumLines: Int, services: PlatformServices, path: ViewPath, tracer: UpdateTracer) {
        self.metrics = metrics
        self.text = text
        self.lineHeight = lineHeight
        self.minimumLines = minimumLines
        self.services = services
        super.init(path: path, tracer: tracer)
    }
    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        var width = max(metrics.minSize.width, proposal.width ?? metrics.idealWidth)
        if !width.isFinite { width = metrics.idealWidth }
        // The bezel adds the same insets as for a single-line field.
        let insets = CGSize(width: metrics.contentInsets.horizontal, height: metrics.contentInsets.vertical)
        let measured = services.measureText(text, proposal: ProposedViewSize(width: max(0, width - insets.width), height: nil)).height
        let height = max(measured, CGFloat(minimumLines) * lineHeight)
        return CGSize(width: width, height: max(metrics.minSize.height, (height + insets.height).rounded(.up)))
    }
    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? VerticalTextFieldLayoutComputer else { return false }
        return other.metrics == metrics && other.text == text && other.lineHeight == lineHeight && other.minimumLines == minimumLines
    }
}

public struct TextField<Label: View>: View {
    let text: Binding<String>
    /// The title (`TextField("Name", ...)`): the placeholder, or the row label in forms.
    var title: Text?
    var labelView: AnyView?
    var promptText: Text?
    var axis: Axis = .horizontal
    @Environment(\.isInForm) private var isInForm
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.textInputSuggestions) private var suggestions
    @Environment(\.focusRequest) private var externalFocus
    @FocusState private var isEditing: Bool

    init(text: Binding<String>, title: Text?, label: AnyView? = nil, prompt: Text?, axis: Axis = .horizontal) {
        self.text = text
        self.title = title
        self.labelView = label
        self.promptText = prompt
        self.axis = axis
    }

    /// Placeholder outside forms: the prompt, else the title.
    var prompt: String { promptText?.plainString ?? title?.plainString ?? "" }

    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(text: text, title: nil, label: AnyView(label()), prompt: prompt)
    }

    public init(text: Binding<String>, prompt: Text? = nil, axis: Axis, @ViewBuilder label: () -> Label) {
        self.init(text: text, title: nil, label: AnyView(label()), prompt: prompt, axis: axis)
    }

    public init<F: ParseableFormatStyle>(value: Binding<F.FormatInput>, format: F, prompt: Text? = nil, @ViewBuilder label: () -> Label) where F.FormatOutput == String {
        self.init(text: Self.formatted(value, format), title: nil, label: AnyView(label()), prompt: prompt)
    }

    static func formatted<F: ParseableFormatStyle>(_ value: Binding<F.FormatInput>, _ format: F) -> Binding<String> where F.FormatOutput == String {
        Binding(get: { format.format(value.wrappedValue) }, set: { if let parsed = try? format.parseStrategy.parse($0) { value.wrappedValue = parsed } })
    }

    /// The field with `textInputSuggestions` (tracking its own focus unless `focused` is set).
    private func input(_ prompt: String) -> some View {
        let editing = $isEditing
        return _TextInput(text: text, prompt: prompt, kind: axis == .vertical ? .verticalField : .field)
            .modifier(_OptionalFocus(binding: suggestions != nil && externalFocus == nil ? editing : nil))
            .modifier(_SuggestionsPopover(suggestions: suggestions, isEditing: isEditing || (externalFocus?.isFocused() ?? false), text: text) { editing.wrappedValue = false })
    }

    public var body: some View {
        if isInForm && !labelsHidden {
            // Grouped form row: the title labels the row; the borderless field's text is trailing.
            _FormLabeledRow {
                if let labelView { labelView } else if let title { title }
            } control: {
                input(promptText?.plainString ?? "")
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
        } else if suggestions != nil {
            input(prompt)
        } else {
            _TextInput(text: text, prompt: prompt, kind: axis == .vertical ? .verticalField : .field)
        }
    }
}

extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text, title: Text(titleKey), prompt: nil)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, title: Text(title), prompt: nil)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        self.init(text: text, title: Text(titleKey), prompt: prompt)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.init(text: text, title: Text(title), prompt: prompt)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {
        self.init(text: text, title: Text(titleKey), prompt: nil, axis: axis)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {
        self.init(text: text, title: Text(title), prompt: nil, axis: axis)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?, axis: Axis) {
        self.init(text: text, title: Text(titleKey), prompt: prompt, axis: axis)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?, axis: Axis) {
        self.init(text: text, title: Text(title), prompt: prompt, axis: axis)
    }

    public init<F: ParseableFormatStyle>(_ titleKey: LocalizedStringKey, value: Binding<F.FormatInput>, format: F, prompt: Text? = nil) where F.FormatOutput == String {
        self.init(text: Self.formatted(value, format), title: Text(titleKey), prompt: prompt)
    }

    @_disfavoredOverload public init<S: StringProtocol, F: ParseableFormatStyle>(_ title: S, value: Binding<F.FormatInput>, format: F, prompt: Text? = nil) where F.FormatOutput == String {
        self.init(text: Self.formatted(value, format), title: Text(title), prompt: prompt)
    }

    /// A field editing a value through a `Formatter`.
    public init<V>(_ titleKey: LocalizedStringKey, value: Binding<V>, formatter: Formatter, prompt: Text? = nil) {
        self.init(text: Self.formatterBinding(value, formatter), title: Text(titleKey), prompt: prompt)
    }

    @_disfavoredOverload public init<S: StringProtocol, V>(_ title: S, value: Binding<V>, formatter: Formatter, prompt: Text? = nil) {
        self.init(text: Self.formatterBinding(value, formatter), title: Text(title), prompt: prompt)
    }

    static func formatterBinding<V>(_ value: Binding<V>, _ formatter: Formatter) -> Binding<String> {
        Binding(get: { formatter.string(for: value.wrappedValue) ?? "" }, set: { string in
            var object: AnyObject?
            if formatter.getObjectValue(&object, for: string, errorDescription: nil), let typed = object as? V { value.wrappedValue = typed }
        })
    }
}

public struct SecureField<Label: View>: View {
    let text: Binding<String>
    var title: Text?
    var labelView: AnyView?
    var promptText: Text?
    @Environment(\.isInForm) private var isInForm
    @Environment(\.labelsHidden) private var labelsHidden

    init(text: Binding<String>, title: Text?, label: AnyView? = nil, prompt: Text?) {
        self.text = text
        self.title = title
        self.labelView = label
        self.promptText = prompt
    }

    var prompt: String { promptText?.plainString ?? title?.plainString ?? "" }

    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(text: text, title: nil, label: AnyView(label()), prompt: prompt)
    }

    public var body: some View {
        if isInForm && !labelsHidden {
            _FormLabeledRow {
                if let labelView { labelView } else if let title { title }
            } control: {
                _TextInput(text: text, prompt: promptText?.plainString ?? "", kind: .secure)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            }
        } else {
            _TextInput(text: text, prompt: prompt, kind: .secure)
        }
    }
}

extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text, title: Text(titleKey), prompt: nil)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, title: Text(title), prompt: nil)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text?) {
        self.init(text: text, title: Text(titleKey), prompt: prompt)
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.init(text: text, title: Text(title), prompt: prompt)
    }
}

/// A grouped form row (macOS 26): the label leading; the control trailing, offered at most 55%
/// of the row's width (flexible controls such as sliders and fields take all of it).
struct _FormLabeledRow<Label: View, Control: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    var body: some View {
        _FormRowLayout {
            label
            control
        }
    }
}

struct _FormRowLayout: Layout {
    static let controlFraction: CGFloat = 0.55
    static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + Self.spacing + subviews[1].sizeThatFits(.unspecified).width)
        let (labelSize, controlSize) = sizes(width: width, subviews)
        return CGSize(width: width, height: max(labelSize.height, controlSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (labelSize, controlSize) = sizes(width: bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(labelSize))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(controlSize))
    }

    private func sizes(width: CGFloat, _ subviews: Subviews) -> (CGSize, CGSize) {
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: (width * Self.controlFraction).rounded(), height: nil))
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, width - control.width - Self.spacing), height: nil))
        return (label, control)
    }
}

public struct TextEditor: View {
    let text: Binding<String>
    public init(text: Binding<String>) { self.text = text }
    public var body: some View { _TextInput(text: text, prompt: "", kind: .editor) }
}

// MARK: - Slider

public struct Slider<Label: View>: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let label: Label?
    let minimumLabel: AnyView?
    let maximumLabel: AnyView?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.labelsHidden) private var labelsHidden

    @Environment(\.isInForm) private var isInForm

    public var body: some View {
        if isInForm, let label, !labelsHidden {
            _FormLabeledRow { label } control: {
                HStack(spacing: 6) {
                    if let minimumLabel { minimumLabel }
                    _SliderControl(value: value, range: range, step: step, onEditingChanged: onEditingChanged)
                    if let maximumLabel { maximumLabel }
                }
            }
        } else {
            HStack(spacing: 6) {
                if let label, !labelsHidden { label }
                if let minimumLabel { minimumLabel }
                _SliderControl(value: value, range: range, step: step, onEditingChanged: onEditingChanged)
                if let maximumLabel { maximumLabel }
            }
        }
    }
}

extension Slider {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil, @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.onEditingChanged = onEditingChanged
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = step.map { Double($0) }
        self.label = label()
        self.minimumLabel = nil
        self.maximumLabel = nil
    }

    public init<V: BinaryFloatingPoint, Min: View, Max: View>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil, @ViewBuilder label: () -> Label, @ViewBuilder minimumValueLabel: () -> Min, @ViewBuilder maximumValueLabel: () -> Max, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.onEditingChanged = onEditingChanged
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = step.map { Double($0) }
        self.label = label()
        self.minimumLabel = AnyView(minimumValueLabel())
        self.maximumLabel = AnyView(maximumValueLabel())
    }
}

extension Slider where Label == EmptyView {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.onEditingChanged = onEditingChanged
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = step.map { Double($0) }
        self.label = nil
        self.minimumLabel = nil
        self.maximumLabel = nil
    }
}

struct _SliderControl: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Slider")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let slider = view.attribute.value
            var resolved = ResolvedSlider(value: slider.value.wrappedValue, range: slider.range, isEnabled: environment.value.isEnabled)
            resolved.controlSize = environment.value.controlSize
            resolved.showsThumb = environment.value._sliderThumbVisibility != .hidden
            return .slider(resolved)
        }
        let viewAttribute = view.attribute
        var actions = RenderActions()
        actions.setDouble = { [weak viewAttribute] newValue in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies {
                let slider = viewAttribute.value
                var value = newValue
                if let step = slider.step, step > 0 {
                    value = (((value - slider.range.lowerBound) / step).rounded() * step) + slider.range.lowerBound
                }
                slider.value.wrappedValue = min(max(value, slider.range.lowerBound), slider.range.upperBound)
            }
        }
        actions.editingChanged = { [weak viewAttribute] editing in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.onEditingChanged(editing) }
        }
        inputs.makePlatformNode(content: content, actions: actions)
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute {
            var metrics = services.controlMetrics(.slider)
            // SwiftUI's slider heights — classic: regular 20, small 16, mini 12, 19 in grouped
            // form rows; modern: regular 16, small 14, mini 12.
            let modern = environment.value._controlDesign == .modern
            switch environment.value.controlSize {
            case .small: metrics.minSize.height = modern ? 14 : 16
            case .mini: metrics.minSize.height = 12
            default: metrics.minSize.height = modern ? 16 : environment.value.isInForm ? 19 : 20
            }
            return ControlLayoutComputer(metrics: metrics, path: path, tracer: tracer)
        })
    }
}

struct SliderThumbVisibilityKey: EnvironmentKey { static let defaultValue = Visibility.automatic }

extension EnvironmentValues {
    var _sliderThumbVisibility: Visibility {
        get { self[SliderThumbVisibilityKey.self] }
        set { self[SliderThumbVisibilityKey.self] = newValue }
    }
}

extension View {
    /// Whether sliders show their thumb (a hidden thumb leaves a progress-like track).
    public func sliderThumbVisibility(_ visibility: Visibility) -> some View {
        environment(\._sliderThumbVisibility, visibility)
    }
}
