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

    public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(titleKey) }
    }

    public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension Button where Label == SwiftUI2Core.Label<Text, Image> {
    public init(_ title: String, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }

    public init(_ title: String, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
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
            return .button(ResolvedButton(style: style.value, isEnabled: env.isEnabled && env.allowsHitTesting, tint: tint))
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
            case .borderedProminent: env.foregroundStyle = AnyShapeStyle(Color.white)
            case .link: env.foregroundStyle = AnyShapeStyle(env.tint ?? .accentColor)
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
        let layout = inputs.makeLayoutAttribute {
            ButtonComputer(metrics: services.controlMetrics(.button(style.value)).scaled(for: controlSize.value), child: labelLayout.value, path: path, tracer: tracer)
        }
        labelGeometry.setRule {
            (layout.value as! ButtonComputer).placeChild(in: geometry.value, child: labelLayout.value)
        }
        return _ViewOutputs(layout: layout, preferences: label.preferences)
    }
}

extension ControlMetrics {
    /// Bordered controls at a control size (measured on macOS SwiftUI: mini 13pt tall with 5pt
    /// insets, small 16/6, regular 20/8, large 28/8; extra large is drawn like regular).
    func scaled(for size: ControlSize) -> ControlMetrics {
        guard minSize.height > 0 else { return self }
        var copy = self
        switch size {
        case .mini:
            copy.minSize.height = 13
            copy.contentInsets = EdgeInsets(top: 1, leading: 5, bottom: 1, trailing: 5)
        case .small:
            copy.minSize.height = 16
            copy.contentInsets = EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
        case .large:
            copy.minSize.height = 28
            copy.contentInsets = EdgeInsets(top: 6, leading: contentInsets.leading, bottom: 6, trailing: contentInsets.trailing)
        case .regular, .extraLarge:
            break
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
        return CGSize(
            width: max(metrics.minSize.width, label.width + insets.horizontal),
            height: max(metrics.minSize.height, label.height + insets.vertical)
        )
    }

    override var spacing: ViewSpacing { .default }

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

    public var body: some View {
        if let customStyle {
            customStyle.make(ToggleStyleConfiguration(label: .init(content: AnyView(label)), isOn: isOn))
        } else if kind == .button {
            Button { isOn.wrappedValue.toggle() } label: { label }
                .environment(\.buttonStyle, isOn.wrappedValue ? .borderedProminent : .bordered)
        } else if isInForm && (kind == .switch || kind == .automatic) {
            HStack(spacing: 8) {
                if !labelsHidden {
                    label
                    Spacer(minLength: 0)
                }
                _ToggleControl(isOn: isOn).environment(\.toggleStyle, .switch)
            }
        } else if kind == .switch {
            // Outside forms a switch hugs its label (measured on macOS SwiftUI).
            HStack(spacing: 8) {
                if !labelsHidden { label }
                _ToggleControl(isOn: isOn)
            }
        } else {
            HStack(spacing: controlSize == .small || controlSize == .mini ? 4 : 5) {
                _ToggleControl(isOn: isOn)
                if !labelsHidden { label.font(font ?? Font.controlFont(controlSize)) }
            }
        }
    }
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(titleKey) }
    }

    public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

extension Toggle where Label == SwiftUI2Core.Label<Text, Image> {
    public init(_ title: String, systemImage: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI2Core.Label(title, systemImage: systemImage) }
    }
}

/// The platform checkbox / switch.
public struct _ToggleControl: View {
    let isOn: Binding<Bool>
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "ToggleControl")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let env = environment.value
            let style: ToggleStyleKind = env.toggleStyle == .switch ? .switch : .checkbox
            return .toggle(ResolvedToggle(isOn: view.attribute.value.isOn.wrappedValue, style: style, isEnabled: env.isEnabled))
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
    enum Kind: Hashable { case field, secure, editor }
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
                style: env.textFieldStyle, wantsFocus: env.focusRequest?.isFocused() ?? false,
                color: ForegroundStyle()._resolveColor(in: env)
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
            var metrics = services.controlMetrics(.textField)
            if kind == .editor { metrics.minSize.height = 40 }
            // SwiftUI: a text field's ideal width is its prompt's width plus the bezel insets;
            // secure fields have no ideal width.
            let prompt = view.attribute.value.prompt
            if kind == .field, !prompt.isEmpty {
                let font = (environment.value.font ?? .defaultFont).resolve()
                let promptText = ResolvedText(string: prompt, font: font, color: .init(red: 0, green: 0, blue: 0, opacity: 1), lineLimit: 1, alignment: .leading, strikethrough: false, underline: false)
                metrics.idealWidth = services.measureText(promptText, proposal: .unspecified).width + 8
            } else if kind == .secure {
                metrics.idealWidth = 0
            }
            return ControlLayoutComputer(metrics: metrics, flexibleHeight: kind == .editor, path: path, tracer: tracer)
        })
    }
}

public struct TextField<Label: View>: View {
    let text: Binding<String>
    let prompt: String
    @Environment(\.isInForm) private var isInForm
    @Environment(\.labelsHidden) private var labelsHidden

    public var body: some View {
        if isInForm && !labelsHidden {
            HStack {
                Text(prompt)
                Spacer(minLength: 16)
                _TextInput(text: text, prompt: "", kind: .field)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 240)
            }
        } else {
            _TextInput(text: text, prompt: prompt, kind: .field)
        }
    }
}

extension TextField where Label == Text {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.text = text
        self.prompt = String(title)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.text = text
        self.prompt = titleKey.key
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        self.text = text
        self.prompt = prompt?.plainString ?? String(title)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {
        self.text = text
        self.prompt = String(title)
    }

    public init<S: StringProtocol, F: ParseableFormatStyle>(_ title: S, value: Binding<F.FormatInput>, format: F) where F.FormatOutput == String {
        self.prompt = String(title)
        self.text = Binding(get: { format.format(value.wrappedValue) }, set: { if let parsed = try? format.parseStrategy.parse($0) { value.wrappedValue = parsed } })
    }
}

public struct SecureField<Label: View>: View {
    let text: Binding<String>
    let prompt: String
    @Environment(\.isInForm) private var isInForm

    public var body: some View {
        if isInForm {
            HStack {
                Text(prompt)
                Spacer(minLength: 16)
                _TextInput(text: text, prompt: "", kind: .secure)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 240)
            }
        } else {
            _TextInput(text: text, prompt: prompt, kind: .secure)
        }
    }
}

extension SecureField where Label == Text {
    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.text = text
        self.prompt = String(title)
    }

    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.text = text
        self.prompt = titleKey.key
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
    @Environment(\.labelsHidden) private var labelsHidden

    public var body: some View {
        HStack(spacing: 6) {
            if let label, !labelsHidden { label }
            if let minimumLabel { minimumLabel }
            _SliderControl(value: value, range: range, step: step)
            if let maximumLabel { maximumLabel }
        }
    }
}

extension Slider {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil, @ViewBuilder label: () -> Label) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = step.map { Double($0) }
        self.label = label()
        self.minimumLabel = nil
        self.maximumLabel = nil
    }

    public init<V: BinaryFloatingPoint, Min: View, Max: View>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label, @ViewBuilder minimumValueLabel: () -> Min, @ViewBuilder maximumValueLabel: () -> Max) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = nil
        self.label = label()
        self.minimumLabel = AnyView(minimumValueLabel())
        self.maximumLabel = AnyView(maximumValueLabel())
    }
}

extension Slider where Label == EmptyView {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil) where V.Stride: BinaryFloatingPoint {
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

    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Slider")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let slider = view.attribute.value
            return .slider(ResolvedSlider(value: slider.value.wrappedValue, range: slider.range, isEnabled: environment.value.isEnabled))
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
        inputs.makePlatformNode(content: content, actions: actions)
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute {
            ControlLayoutComputer(metrics: services.controlMetrics(.slider), path: path, tracer: tracer)
        })
    }
}
