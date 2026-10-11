import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Environment support

public enum ControlSize: Hashable, Sendable, CaseIterable { case mini, small, regular, large, extraLarge }

public struct KeyEquivalent: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public let character: Character
    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }
    public static let `return` = KeyEquivalent("\r")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let delete = KeyEquivalent("\u{8}")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let deleteForward = KeyEquivalent("\u{7F}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
    public static let clear = KeyEquivalent("\u{F739}")
}

public struct EventModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = EventModifiers(rawValue: 1)
    public static let control = EventModifiers(rawValue: 2)
    public static let option = EventModifiers(rawValue: 4)
    public static let command = EventModifiers(rawValue: 8)
    public static let all: EventModifiers = [.shift, .control, .option, .command]
}

public struct KeyboardShortcut: Hashable, Sendable {
    public struct Localization: Hashable, Sendable {
        let value: Int
        public static let automatic = Localization(value: 0)
        public static let withoutMirroring = Localization(value: 1)
        public static let custom = Localization(value: 2)
    }

    public var key: KeyEquivalent
    public var modifiers: EventModifiers
    public var localization: Localization = .automatic
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])
}

/// Two-way connection between a `@FocusState` and a focusable control.
@MainActor
struct FocusRequest {
    let isFocused: @MainActor () -> Bool
    let setFocused: @MainActor (Bool) -> Void
}

extension FocusRequest: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: FocusRequest, _ rhs: FocusRequest) -> Bool { false }
}

public struct OpenURLAction: @unchecked Sendable {
    let handler: @MainActor (URL) -> Void
    public init(handler: @escaping @MainActor (URL) -> Result) {
        self.handler = { _ = handler($0) }
    }
    init(_ handler: @escaping @MainActor (URL) -> Void) { self.handler = handler }
    @MainActor public func callAsFunction(_ url: URL) { handler(url) }

    public enum Result: Sendable { case handled, discarded, systemAction }
}

public struct DismissAction: @unchecked Sendable {
    let action: @MainActor () -> Void
    @MainActor public func callAsFunction() { action() }
}

struct AllowsHitTestingKey: EnvironmentKey { static let defaultValue = true }
struct KeyboardShortcutKey: EnvironmentKey { static let defaultValue: KeyboardShortcut? = nil }
struct ControlSizeKey: EnvironmentKey { static let defaultValue = ControlSize.regular }
struct LabelsHiddenKey: EnvironmentKey { static let defaultValue = false }
struct TextFieldStyleKey: EnvironmentKey { static let defaultValue = TextFieldStyleKind.automatic }
struct FocusRequestKey: EnvironmentKey { static let defaultValue: FocusRequest? = nil }
struct SubmitActionKey: EnvironmentKey { static let defaultValue: (@MainActor (SubmitTriggers) -> Void)? = nil }
struct SubmitTriggerKey: EnvironmentKey { static let defaultValue = SubmitTriggers.text }
struct OpenURLKey: EnvironmentKey { static let defaultValue = OpenURLAction { _ in } }
struct DismissKey: EnvironmentKey { static let defaultValue = DismissAction {} }
struct IsPresentedKey: EnvironmentKey { static let defaultValue = false }
struct LabelStyleBoxKey: EnvironmentKey { static let defaultValue: AnyLabelStyleBox? = nil }
struct ImageScaleKey: EnvironmentKey { static let defaultValue = Image.Scale.medium }

extension EnvironmentValues {
    public var allowsHitTesting: Bool {
        get { self[AllowsHitTestingKey.self] }
        set { self[AllowsHitTestingKey.self] = newValue }
    }
    var keyboardShortcut: KeyboardShortcut? {
        get { self[KeyboardShortcutKey.self] }
        set { self[KeyboardShortcutKey.self] = newValue }
    }
    public var controlSize: ControlSize {
        get { self[ControlSizeKey.self] }
        set { self[ControlSizeKey.self] = newValue }
    }
    var labelsHidden: Bool {
        get { self[LabelsHiddenKey.self] }
        set { self[LabelsHiddenKey.self] = newValue }
    }
    var textFieldStyle: TextFieldStyleKind {
        get { self[TextFieldStyleKey.self] }
        set { self[TextFieldStyleKey.self] = newValue }
    }
    var focusRequest: FocusRequest? {
        get { self[FocusRequestKey.self] }
        set { self[FocusRequestKey.self] = newValue }
    }
    /// `onSubmit` actions; each runs for the triggers it was registered with.
    var submitAction: (@MainActor (SubmitTriggers) -> Void)? {
        get { self[SubmitActionKey.self] }
        set { self[SubmitActionKey.self] = newValue }
    }
    /// What submitting a text field inside this environment counts as (search fields: `.search`).
    var submitTrigger: SubmitTriggers {
        get { self[SubmitTriggerKey.self] }
        set { self[SubmitTriggerKey.self] = newValue }
    }
    public var openURL: OpenURLAction {
        get { self[OpenURLKey.self] }
        set { self[OpenURLKey.self] = newValue }
    }
    public var dismiss: DismissAction {
        get { self[DismissKey.self] }
        set { self[DismissKey.self] = newValue }
    }
    public var isPresented: Bool {
        get { self[IsPresentedKey.self] }
        set { self[IsPresentedKey.self] = newValue }
    }
    var labelStyleBox: AnyLabelStyleBox? {
        get { self[LabelStyleBoxKey.self] }
        set { self[LabelStyleBoxKey.self] = newValue }
    }
    public var imageScale: Image.Scale {
        get { self[ImageScaleKey.self] }
        set { self[ImageScaleKey.self] = newValue }
    }
}

extension View {
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        transformEnvironment(\.allowsHitTesting) { $0 = $0 && enabled }
    }

    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        environment(\.keyboardShortcut, KeyboardShortcut(key, modifiers: modifiers))
    }

    /// Shortcuts are not remapped for keyboard layouts (`localization` is accepted).
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, localization: KeyboardShortcut.Localization) -> some View {
        keyboardShortcut(key, modifiers: modifiers)
    }

    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        environment(\.keyboardShortcut, shortcut)
    }

    public func controlSize(_ size: ControlSize) -> some View { environment(\.controlSize, size) }
    public func labelsHidden() -> some View { environment(\.labelsHidden, true) }
    public func help(_ text: String) -> some View { modifier(_HelpModifier(text: text)) }
    public func help(_ text: Text) -> some View { modifier(_HelpModifier(text: text.plainString)) }
    public func help(_ key: LocalizedStringKey) -> some View { modifier(_HelpModifier(text: Text(key).plainString)) }
    public func imageScale(_ scale: Image.Scale) -> some View { environment(\.imageScale, scale) }

    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping @MainActor () -> Void) -> some View {
        transformEnvironment(\.submitAction) { existing in
            let previous = existing
            existing = { trigger in
                previous?(trigger)
                if triggers.contains(trigger) { action() }
            }
        }
    }

    public func submitLabel(_ label: SubmitLabel) -> some View { self }
}

public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1)
    public static let search = SubmitTriggers(rawValue: 2)
}

public enum SubmitLabel: Sendable { case done, go, send, join, route, search, `return`, next, `continue` }

// MARK: - FocusState

@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicProperty {
    var initial: Value
    var location: StoredLocation<Value>?

    @propertyWrapper
    public struct Binding {
        let location: AnyLocation<Value>
        @MainActor public var wrappedValue: Value {
            get { location.get() }
            nonmutating set { location.set(newValue, transaction: Transaction()) }
        }
        public var projectedValue: Binding { self }
    }

    public init() where Value == Bool { initial = false }
    public init<T: Hashable>() where Value == T? { initial = nil }

    public var wrappedValue: Value {
        get { location?.get() ?? initial }
        nonmutating set { location?.set(newValue, transaction: Transaction()) }
    }

    public var projectedValue: Binding {
        Binding(location: location ?? StoredLocation(attribute: MainActor.assumeIsolated { _orphanAttribute(initial) }))
    }
}

@MainActor
private func _orphanAttribute<Value>(_ value: Value) -> Attribute<Value> {
    Attribute(Subgraph(graph: AttributeGraph()), value: value)
}

extension FocusState: _DynamicPropertyInstallable {
    mutating func _install(slot: inout AnyObject?, context: DynamicPropertyContext) {
        if let existing = slot as? StoredLocation<Value> {
            location = existing
            return
        }
        let created = StoredLocation(attribute: Attribute(context.subgraph, value: initial))
        slot = created
        location = created
    }
}

extension FocusState: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: FocusState, _ rhs: FocusState) -> Bool { true }
}

extension FocusState.Binding: _GraphComparable {
    public nonisolated static func _isIdentical(_ lhs: FocusState.Binding, _ rhs: FocusState.Binding) -> Bool { lhs.location === rhs.location }
}

extension View {
    /// Focus of the `searchable` field.
    public func searchFocused(_ condition: FocusState<Bool>.Binding) -> some View {
        environment(\.searchFocusRequest, FocusRequest(
            isFocused: { condition.wrappedValue },
            setFocused: { if condition.wrappedValue != $0 { condition.wrappedValue = $0 } }
        ))
    }

    public func focused(_ condition: FocusState<Bool>.Binding) -> some View {
        environment(\.focusRequest, FocusRequest(
            isFocused: { condition.wrappedValue },
            setFocused: { if condition.wrappedValue != $0 { condition.wrappedValue = $0 } }
        ))
    }

    public func focused<V: Hashable>(_ binding: FocusState<V?>.Binding, equals value: V) -> some View {
        environment(\.focusRequest, FocusRequest(
            isFocused: { binding.wrappedValue == value },
            setFocused: { focused in
                if focused { binding.wrappedValue = value } else if binding.wrappedValue == value { binding.wrappedValue = nil }
            }
        ))
    }

}

// MARK: - Label

public struct LabelStyleConfiguration {
    public struct Title: View {
        let content: AnyView
        public var body: some View { content }
    }
    public struct Icon: View {
        let content: AnyView
        public var body: some View { content }
    }
    public let title: Title
    public let icon: Icon
}

@MainActor @preconcurrency
public protocol LabelStyle {
    associatedtype Body: View
    typealias Configuration = LabelStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

public struct TitleAndIconLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        _IconAndTitle(icon: configuration.icon, title: configuration.title)
    }
}

/// Icon then title, honoring `labelIconToTitleSpacing` and `labelReservedIconWidth`.
struct _IconAndTitle<Icon: View, Title: View>: View {
    let icon: Icon
    let title: Title
    @Environment(\._labelIconSpacing) private var spacing
    @Environment(\._labelReservedIconWidth) private var reservedWidth

    var body: some View {
        HStack(spacing: spacing) {
            if let reservedWidth { icon.frame(width: reservedWidth) } else { icon }
            title
        }
    }
}

struct LabelIconSpacingKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
struct LabelReservedIconWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    var _labelIconSpacing: CGFloat? {
        get { self[LabelIconSpacingKey.self] }
        set { self[LabelIconSpacingKey.self] = newValue }
    }
    var _labelReservedIconWidth: CGFloat? {
        get { self[LabelReservedIconWidthKey.self] }
        set { self[LabelReservedIconWidthKey.self] = newValue }
    }
}

extension View {
    /// Spacing between labels' icons and titles.
    public func labelIconToTitleSpacing(_ spacing: CGFloat) -> some View { environment(\._labelIconSpacing, spacing) }

    /// Width reserved for labels' icons (so titles line up).
    public func labelReservedIconWidth(_ width: CGFloat) -> some View { environment(\._labelReservedIconWidth, width) }
}

public struct TitleOnlyLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.title }
}

public struct IconOnlyLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.icon }
}

public struct DefaultLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { TitleAndIconLabelStyle().makeBody(configuration: configuration) }
}

extension LabelStyle where Self == DefaultLabelStyle { public static var automatic: DefaultLabelStyle { .init() } }
extension LabelStyle where Self == TitleAndIconLabelStyle { public static var titleAndIcon: TitleAndIconLabelStyle { .init() } }
extension LabelStyle where Self == TitleOnlyLabelStyle { public static var titleOnly: TitleOnlyLabelStyle { .init() } }
extension LabelStyle where Self == IconOnlyLabelStyle { public static var iconOnly: IconOnlyLabelStyle { .init() } }

@MainActor
struct AnyLabelStyleBox {
    let make: @MainActor (LabelStyleConfiguration) -> AnyView
    let identity: ObjectIdentifier
    /// The style value: a style whose properties change (e.g. `TabStyle(selected:)`) is a new style.
    nonisolated(unsafe) let style: Any
}

extension AnyLabelStyleBox: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: AnyLabelStyleBox, _ rhs: AnyLabelStyleBox) -> Bool {
        lhs.identity == rhs.identity && GraphComparison.compareAny(lhs.style, rhs.style)
    }
}

extension View {
    public func labelStyle<S: LabelStyle>(_ style: S) -> some View {
        environment(\.labelStyleBox, AnyLabelStyleBox(make: { AnyView(style.makeBody(configuration: $0)) }, identity: ObjectIdentifier(S.self), style: style))
    }
}

public struct Label<Title: View, Icon: View>: View {
    let title: Title
    let icon: Icon
    @Environment(\.labelStyleBox) private var style

    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    public var body: some View {
        let configuration = LabelStyleConfiguration(title: .init(content: AnyView(title)), icon: .init(content: AnyView(icon)))
        if let style {
            style.make(configuration)
        } else {
            _IconAndTitle(icon: icon, title: title)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: name) })
    }

    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {
        self.init(title: { Text(titleKey) }, icon: { Image(systemName: name) })
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, image name: String) {
        self.init(title: { Text(title) }, icon: { Image(name) })
    }
}

// MARK: - Link

public struct Link<Label: View>: View {
    let destination: URL
    let label: Label
    @Environment(\.openURL) private var openURL
    @Environment(\.customButtonStyle) private var customStyle
    @Environment(\.buttonStyle) private var style

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    /// Links look like links by default; an explicit `buttonStyle` (built-in or custom) styles
    /// them like buttons, as in SwiftUI.
    public var body: some View {
        let button = Button { openURL(destination) } label: { label }
        if customStyle == nil, style == .automatic {
            button.buttonStyle(.link)
        } else {
            button
        }
    }
}

extension Link where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, destination: URL) {
        self.init(destination: destination) { Text(titleKey) }
    }
}

// MARK: - Stepper

public struct Stepper<Label: View>: View {
    let label: Label
    let onIncrement: (@MainActor () -> Void)?
    let onDecrement: (@MainActor () -> Void)?
    /// `format:` steppers show the value in an editable field.
    var valueField: AnyView?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\._controlDesign) private var design
    @Environment(\.controlSize) private var controlSize
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm

    public init(@ViewBuilder label: () -> Label, onIncrement: (@MainActor () -> Void)?, onDecrement: (@MainActor () -> Void)?) {
        self.label = label()
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
    }

    public init<V: Strideable>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.onIncrement = { value.wrappedValue = min(value.wrappedValue.advanced(by: step), bounds.upperBound) }
        self.onDecrement = { value.wrappedValue = max(value.wrappedValue.advanced(by: -step), bounds.lowerBound) }
    }

    public init<V: Strideable>(value: Binding<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.onIncrement = { value.wrappedValue = value.wrappedValue.advanced(by: step) }
        self.onDecrement = { value.wrappedValue = value.wrappedValue.advanced(by: -step) }
    }

    public init<V: Strideable, F: ParseableFormatStyle>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, format: F, @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where F.FormatInput == V, F.FormatOutput == String {
        self.init(value: value, in: bounds, step: step, label: label)
        self.valueField = AnyView(TextField("", value: value, format: format).labelsHidden())
        self.onEditingChanged = onEditingChanged
    }

    public init<V: Strideable, F: ParseableFormatStyle>(value: Binding<V>, step: V.Stride = 1, format: F, @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where F.FormatInput == V, F.FormatOutput == String {
        self.init(value: value, step: step, label: label)
        self.valueField = AnyView(TextField("", value: value, format: format).labelsHidden())
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        if isInForm, !labelsHidden {
            // Grouped form row: a mini (classic) or small (modern) stepper trailing.
            _FormLabeledRow { label } control: {
                HStack(spacing: 6) {
                    if let valueField { valueField.frame(width: 60) }
                    if design == .modern { arrows(width: 17, height: 10.25, symbolSize: 7) } else { arrows(width: 13, height: 8, symbolSize: 6) }
                }
            }
        } else {
            // Measured (classic): label, 8pt, an 80pt value field, 3pt, the 13pt stepper. The
            // whole stepper spaces like a control (not like its label text).
            HStack(spacing: design == .modern ? 8 : 6) {
                if !labelsHidden { label }
                if isInForm { Spacer(minLength: 8) }
                HStack(spacing: design == .modern ? 8 : 3) {
                    if let valueField { valueField.frame(width: design == .modern ? 60 : 80).padding(.leading, design == .modern ? 0 : 2) }
                    // Stepper arrows by control size (mini 13 × 16, small 17 × 20; regular modern
                    // 20 × 24, classic 15 × 20).
                    switch controlSize {
                    case .mini: arrows(width: 13, height: 8, symbolSize: 6)
                    case .small: arrows(width: 17, height: 10, symbolSize: 7)
                    default:
                        if design == .modern { arrows(width: 20, height: 12, symbolSize: 8) } else { arrows(width: valueField == nil ? 15 : 13, height: 10, symbolSize: 8) }
                    }
                }
            }
            .modifier(_ControlSpacingLayout())
        }
    }

    private func arrows(width: CGFloat, height: CGFloat, symbolSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button { onIncrement?() } label: { Image(systemName: "chevron.up").font(.system(size: symbolSize, weight: .bold)).frame(width: width, height: height) }
                .buttonStyle(.plain)
                .disabled(onIncrement == nil)
            Button { onDecrement?() } label: { Image(systemName: "chevron.down").font(.system(size: symbolSize, weight: .bold)).frame(width: width, height: height) }
                .buttonStyle(.plain)
                .disabled(onDecrement == nil)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2)))
    }
}

extension Stepper where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1) {
        self.init(value: value, in: bounds, step: step) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, step: V.Stride = 1) {
        self.init(value: value, step: step) { Text(title) }
    }

    public init<V: Strideable>(_ titleKey: LocalizedStringKey, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1) {
        self.init(value: value, in: bounds, step: step) { Text(titleKey) }
    }

    public init<V: Strideable>(_ titleKey: LocalizedStringKey, value: Binding<V>, step: V.Stride = 1) {
        self.init(value: value, step: step) { Text(titleKey) }
    }

    public init<V: Strideable, F: ParseableFormatStyle>(_ titleKey: LocalizedStringKey, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, format: F) where F.FormatInput == V, F.FormatOutput == String {
        self.init(value: value, in: bounds, step: step, format: format) { Text(titleKey) }
    }

    @_disfavoredOverload public init<S: StringProtocol, V: Strideable, F: ParseableFormatStyle>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, format: F) where F.FormatInput == V, F.FormatOutput == String {
        self.init(value: value, in: bounds, step: step, format: format) { Text(title) }
    }

    public init<V: Strideable, F: ParseableFormatStyle>(_ titleKey: LocalizedStringKey, value: Binding<V>, step: V.Stride = 1, format: F) where F.FormatInput == V, F.FormatOutput == String {
        self.init(value: value, step: step, format: format) { Text(titleKey) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, onIncrement: (@MainActor () -> Void)?, onDecrement: (@MainActor () -> Void)?) {
        self.init(label: { Text(title) }, onIncrement: onIncrement, onDecrement: onDecrement)
    }
}

// MARK: - ProgressView

public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    let fraction: Double?
    let label: Label?
    let currentValueLabel: CurrentValueLabel?
    /// `ProgressView(timerInterval:)`: the fraction follows the clock.
    var timer: (interval: ClosedRange<Date>, countsDown: Bool)?

    init(fraction: Double?, label: Label?, currentValueLabel: CurrentValueLabel?) {
        self.fraction = fraction
        self.label = label
        self.currentValueLabel = currentValueLabel
    }

    public var body: some View {
        if let timer {
            TimelineView(.periodic(from: timer.interval.lowerBound, by: 0.5)) { context in
                styled(fraction: Self.timerFraction(timer.interval, countsDown: timer.countsDown, now: context.date))
            }
        } else {
            styled(fraction: fraction)
        }
    }

    private func styled(fraction: Double?) -> some View {
        _StyledView(configuration: ProgressViewStyleConfiguration(
            fractionCompleted: fraction,
            label: label.map { _StyleContent($0) },
            currentValueLabel: currentValueLabel.map { _StyleContent($0) }
        )) { AnyView(DefaultProgressViewStyle().makeBody(configuration: $0)) }
    }

    static func timerFraction(_ interval: ClosedRange<Date>, countsDown: Bool, now: Date) -> Double {
        let total = interval.upperBound.timeIntervalSince(interval.lowerBound)
        let elapsed = now.timeIntervalSince(interval.lowerBound)
        let fraction = total > 0 ? min(1, max(0, elapsed / total)) : 1
        return countsDown ? 1 - fraction : fraction
    }
}

extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    public init() {
        fraction = nil
        label = nil
        currentValueLabel = nil
    }

    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {
        fraction = value.map { total > 0 ? Double($0 / total) : 0 }
        label = nil
        currentValueLabel = nil
    }
}

extension ProgressView where CurrentValueLabel == EmptyView {
    public init(@ViewBuilder label: () -> Label) {
        fraction = nil
        self.label = label()
        currentValueLabel = nil
    }

    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label) {
        fraction = value.map { total > 0 ? Double($0 / total) : 0 }
        self.label = label()
        currentValueLabel = nil
    }
}

extension ProgressView where Label == Text, CurrentValueLabel == EmptyView {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S) {
        fraction = nil
        label = Text(title)
        currentValueLabel = nil
    }

    @_disfavoredOverload public init<S: StringProtocol, V: BinaryFloatingPoint>(_ title: S, value: V?, total: V = 1.0) {
        fraction = value.map { total > 0 ? Double($0 / total) : 0 }
        label = Text(title)
        currentValueLabel = nil
    }
}

extension ProgressView {
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {
        fraction = value.map { total > 0 ? Double($0 / total) : 0 }
        self.label = label()
        self.currentValueLabel = currentValueLabel()
    }
}

struct _LinearProgressBar: View {
    let fraction: Double
    var height: CGFloat = 18
    var body: some View {
        // macOS: an 18pt tall control with a 6pt bar (small/mini: 12pt, 4pt bar), no ideal width.
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height == 18 ? 6 : 4)
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}

struct _CircularProgress: View {
    let fraction: Double
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: size / 8)
            Circle().trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(Color.accentColor, lineWidth: size / 8)
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// Indeterminate spinner: a rotating arc driven by a repeating animation.
struct _Spinner: View {
    let size: CGFloat
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(Color.gray, lineWidth: max(2, size / 10))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Gauge

public struct Gauge<Label: View, CurrentValueLabel: View>: View {
    let fraction: Double
    let label: Label
    let currentValueLabel: CurrentValueLabel?
    let minimumValueLabel: AnyView?
    let maximumValueLabel: AnyView?

    static func fraction<V: BinaryFloatingPoint>(_ value: V, _ bounds: ClosedRange<V>) -> Double {
        bounds.upperBound > bounds.lowerBound ? Double((value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)) : 0
    }

    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label) where CurrentValueLabel == EmptyView {
        fraction = Self.fraction(value, bounds)
        self.label = label()
        currentValueLabel = nil
        minimumValueLabel = nil
        maximumValueLabel = nil
    }

    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {
        fraction = Self.fraction(value, bounds)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        minimumValueLabel = nil
        maximumValueLabel = nil
    }

    public init<V: BinaryFloatingPoint, Minimum: View, Maximum: View>(
        value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label, @ViewBuilder currentValueLabel: () -> CurrentValueLabel,
        @ViewBuilder minimumValueLabel: () -> Minimum, @ViewBuilder maximumValueLabel: () -> Maximum
    ) {
        fraction = Self.fraction(value, bounds)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        self.minimumValueLabel = AnyView(minimumValueLabel())
        self.maximumValueLabel = AnyView(maximumValueLabel())
    }

    public var body: some View {
        _StyledView(configuration: GaugeStyleConfiguration(
            value: max(0, min(1, fraction)),
            label: _StyleContent(label),
            currentValueLabel: currentValueLabel.map { _StyleContent($0) },
            minimumValueLabel: minimumValueLabel.map { _StyleContent($0) },
            maximumValueLabel: maximumValueLabel.map { _StyleContent($0) }
        )) { AnyView(DefaultGaugeStyle().makeBody(configuration: $0)) }
    }
}

extension Gauge where Label == Text, CurrentValueLabel == EmptyView {
    @_disfavoredOverload public init<S: StringProtocol, V: BinaryFloatingPoint>(_ title: S, value: V, in bounds: ClosedRange<V> = 0...1) {
        self.init(value: value, in: bounds) { Text(title) }
    }
}

// MARK: - LabeledContent

public struct LabeledContent<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        _StyledView(configuration: LabeledContentStyleConfiguration(label: _StyleContent(label), content: _StyleContent(content))) {
            AnyView(AutomaticLabeledContentStyle().makeBody(configuration: $0))
        }
    }
}

extension LabeledContent where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    @_disfavoredOverload public init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V) {
        self.init(content: { Text(value) }, label: { Text(title) })
    }

    @_disfavoredOverload public init<S: StringProtocol, F: FormatStyle>(_ title: S, value: F.FormatInput, format: F) where F.FormatOutput == String {
        self.init(content: { Text(value, format: format) }, label: { Text(title) })
    }

    public init<V: StringProtocol>(_ titleKey: LocalizedStringKey, value: V) {
        self.init(content: { Text(value) }, label: { Text(titleKey) })
    }

    public init<F: FormatStyle>(_ titleKey: LocalizedStringKey, value: F.FormatInput, format: F) where F.FormatOutput == String {
        self.init(content: { Text(value, format: format) }, label: { Text(titleKey) })
    }
}

// MARK: - Date & color pickers

public struct DatePickerComponents: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let date = DatePickerComponents(rawValue: 1)
    public static let hourAndMinute = DatePickerComponents(rawValue: 2)
}

public struct DatePicker<Label: View>: View {
    let selection: Binding<Date>
    let components: DatePickerComponents
    let label: Label
    var range: ClosedRange<Date>?
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm

    public init(selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute], @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.components = displayedComponents
        self.label = label()
    }

    public init(selection: Binding<Date>, in range: ClosedRange<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute], @ViewBuilder label: () -> Label) {
        self.init(selection: selection, displayedComponents: displayedComponents, label: label)
        self.range = range
    }

    public init(selection: Binding<Date>, in range: PartialRangeFrom<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute], @ViewBuilder label: () -> Label) {
        self.init(selection: selection, in: range.lowerBound...Date.distantFuture, displayedComponents: displayedComponents, label: label)
    }

    public init(selection: Binding<Date>, in range: PartialRangeThrough<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute], @ViewBuilder label: () -> Label) {
        self.init(selection: selection, in: Date.distantPast...range.upperBound, displayedComponents: displayedComponents, label: label)
    }

    public var body: some View {
        HStack {
            if !labelsHidden { label }
            if isInForm { Spacer(minLength: 8) }
            _DatePickerControl(selection: selection, components: components, range: range)
        }
    }
}

extension DatePicker where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: ClosedRange<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: range, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: PartialRangeFrom<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: range, displayedComponents: displayedComponents) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, in range: PartialRangeThrough<Date>, displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(selection: selection, in: range, displayedComponents: displayedComponents) { Text(title) }
    }
}

struct _DatePickerControl: View {
    let selection: Binding<Date>
    let components: DatePickerComponents
    var range: ClosedRange<Date>? = nil
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "DatePicker")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            let picker = view.attribute.value
            let env = environment.value
            return .datePicker(ResolvedDatePicker(date: picker.selection.wrappedValue, components: picker.components, isEnabled: env.isEnabled, style: env.datePickerStyle, range: picker.range))
        }
        let viewAttribute = view.attribute
        var actions = RenderActions()
        actions.setDate = { [weak viewAttribute] date in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.selection.wrappedValue = date }
        }
        inputs.makePlatformNode(content: content, actions: actions)
        let tracer = inputs.tracer
        let path = inputs.path
        let services = inputs.services
        return _ViewOutputs(layout: inputs.makeLayoutAttribute {
            let components = view.attribute.value.components
            let kind = ControlKind.datePicker(date: components.contains(.date), time: components.contains(.hourAndMinute), style: environment.value.datePickerStyle)
            return FixedLayoutComputer(size: services.controlMetrics(kind).minSize, path: path, tracer: tracer)
        })
    }
}

public struct ColorPicker<Label: View>: View {
    let selection: Binding<Color>
    let label: Label
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm

    public init(selection: Binding<Color>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.label = label()
    }

    public var body: some View {
        HStack {
            if !labelsHidden { label }
            if isInForm { Spacer(minLength: 8) }
            _ColorWell(selection: selection)
        }
    }
}

extension ColorPicker where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.init(selection: selection) { Text(title) }
    }
}

struct _ColorWell: View {
    let selection: Binding<Color>
    var body: Never { primitiveBody(Self.self) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "ColorPicker")
        let environment = inputs.environment
        let content = makeObservedAttribute(inputs.subgraph, of: RenderContent.self, isEqual: { $0 == $1 }) {
            .colorWell(view.attribute.value.selection.wrappedValue.resolve(in: environment.value))
        }
        let viewAttribute = view.attribute
        var actions = RenderActions()
        actions.setColor = { [weak viewAttribute] color in
            guard let viewAttribute else { return }
            AnyAttribute.withoutDependencies { viewAttribute.value.selection.wrappedValue = Color(color) }
        }
        inputs.makePlatformNode(content: content, actions: actions)
        let tracer = inputs.tracer
        let path = inputs.path
        return _ViewOutputs(layout: inputs.makeLayoutAttribute {
            FixedLayoutComputer(size: environment.value._controlDesign == ControlDesign.modern ? CGSize(width: 48, height: 24) : CGSize(width: 44, height: 23), path: path, tracer: tracer)
        })
    }
}

// MARK: - ContentUnavailableView, GroupBox

public struct ContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    let label: Label
    let description: Description
    let actions: Actions

    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() }, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    public var body: some View {
        // Metrics measured from macOS SwiftUI (content is centered; the bottom inset depends on
        // which parts are present).
        let hasDescription = !_isEmptyContent(description)
        let hasActions = !_isEmptyContent(actions)
        VStack(spacing: 0) {
            label.labelStyle(_VerticalLabelStyle()).font(.title3).foregroundStyle(.secondary)
            if hasDescription {
                description.font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 7)
            }
            if hasActions {
                actions.padding(.top, 17)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, hasActions ? 18 : hasDescription ? 40 : 27)
        // Like SwiftUI's: it can shrink to nothing vertically (and to its horizontal padding);
        // centered when it fits, else showing its top.
        .modifier(_UnavailableFrame())
        .clipped()
        .padding(.horizontal, 20)
    }
}

struct _UnavailableFrame: ViewModifier {
    func body(content: Content) -> some View { _UnavailableLayout { content } }
}

/// Takes the proposed size (any size down to zero); the content is centered when it fits and
/// top-aligned when it doesn't.
struct _UnavailableLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let y = ideal.height <= bounds.height ? bounds.midY - ideal.height / 2 : bounds.minY
        child.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: ideal.height))
    }
}

/// The parts of `ContentUnavailableView.search`.
public struct SearchUnavailableContent {
    public struct Label: View {
        public var body: some View { _SwiftUICore.Label("No Results", systemImage: "magnifyingglass") }
    }

    public struct Description: View {
        let text: String?
        public var body: some View {
            if let text, !text.isEmpty {
                Text("Check the spelling or try a new search for “\(text)”.")
            } else {
                Text("Check the spelling or try a new search.")
            }
        }
    }

    public struct Actions: View {
        public var body: some View { EmptyView() }
    }
}

extension ContentUnavailableView where Label == SearchUnavailableContent.Label, Description == SearchUnavailableContent.Description, Actions == SearchUnavailableContent.Actions {
    /// The standard "No Results" view for searches.
    public static var search: ContentUnavailableView {
        ContentUnavailableView(label: { SearchUnavailableContent.Label() }, description: { SearchUnavailableContent.Description(text: nil) }, actions: { SearchUnavailableContent.Actions() })
    }

    public static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(label: { SearchUnavailableContent.Label() }, description: { SearchUnavailableContent.Description(text: text) }, actions: { SearchUnavailableContent.Actions() })
    }
}

/// Whether a builder result is statically empty (`EmptyView`, or a `nil` optional view).
func _isEmptyContent<V: View>(_ view: V) -> Bool {
    if V.self == EmptyView.self || V.self == SearchUnavailableContent.Actions.self { return true }
    if let optional = view as? any _OptionalView { return optional._isNil }
    return false
}

protocol _OptionalView { var _isNil: Bool { get } }
extension Optional: _OptionalView {
    var _isNil: Bool { self == nil }
}

struct _VerticalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 24) {
            configuration.icon.font(.system(size: 36, weight: .regular)).foregroundStyle(.tertiary)
            configuration.title.fontWeight(.bold)
        }
    }
}

extension ContentUnavailableView where Label == _SwiftUICore.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String, description: Text? = nil) {
        self.init(label: { _SwiftUICore.Label(title, systemImage: name) }, description: { description })
    }
}

public struct GroupBox<Label: View, Content: View>: View {
    let label: Label?
    let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        _StyledView(configuration: GroupBoxStyleConfiguration(label: _StyleContent(label), content: _StyleContent(content))) {
            AnyView(DefaultGroupBoxStyle().makeBody(configuration: $0))
        }
    }
}

extension GroupBox where Label == EmptyView {
    public init(@ViewBuilder content: () -> Content) {
        self.label = nil
        self.content = content()
    }
}

extension GroupBox where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.label = Text(title)
        self.content = content()
    }
}

// MARK: - DisclosureGroup

public struct DisclosureGroup<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let isExpandedBinding: Binding<Bool>?
    @State private var localExpanded = false

    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
        self.isExpandedBinding = isExpanded
    }

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
        self.isExpandedBinding = nil
    }

    private var isExpanded: Binding<Bool> { isExpandedBinding ?? $localExpanded }

    public var body: some View {
        _DisclosureGroupRows(label: label, content: content, isExpanded: isExpanded)
    }
}

/// Outline row traits: the row's depth and, for a disclosure group's label, its expansion.
enum OutlineLevelTraitKey: _ViewTraitKey {
    static var defaultValue: Int? { nil }
}

enum OutlineDisclosureTraitKey: _ViewTraitKey {
    static var defaultValue: Binding<Bool>? { nil }
}

/// A disclosure group: styled (chevron button and indented content) outside lists; inside a
/// List's rows it contributes its label as an outline row followed, while expanded, by its
/// content's rows one level deeper (like SwiftUI's NSOutlineView-backed lists).
struct _DisclosureGroupRows<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let isExpanded: Binding<Bool>

    var body: Never { primitiveBody(Self.self) }

    var styled: _StyledDisclosureGroup<Label, Content> { _StyledDisclosureGroup(label: label, content: content, isExpanded: isExpanded) }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        _StyledDisclosureGroup<Label, Content>._makeView(view: view.project(inputs) { $0.styled }, inputs: inputs)
    }

    static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        guard let level = inputs.outlineLevel else { return .unary(view: view, inputs: inputs) }
        var traits = ViewTraits()
        traits[OutlineLevelTraitKey.self] = Attribute<Int?>(inputs.subgraph, value: level)
        traits[OutlineDisclosureTraitKey.self] = Attribute<Binding<Bool>?>(inputs.subgraph, isEqual: { $0?.location === $1?.location }) {
            view.attribute.value.isExpanded
        }
        let labelElement = ViewListElement(traits: traits) { placement in
            Label._makeView(view: view.project(inputs) { $0.label }, inputs: inputs.instantiate(placement))
        }
        let expanded = Attribute<Bool>(inputs.subgraph, isEqual: { $0 == $1 }) { view.attribute.value.isExpanded.wrappedValue }
        var childInputs = inputs
        childInputs.outlineLevel = level + 1
        let children = makeKeyedList(inputs: childInputs, key: expanded, component: { _ in .branch(0) }) { isExpanded, inputs in
            guard isExpanded else { return ViewList(nodes: []) }
            let rows = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs).list
            // Plain child rows sit one level deeper (nested groups already set their own level).
            let depth = Attribute<Int?>(inputs.subgraph, value: level + 1)
            return rows.mapElements(in: inputs.subgraph) { element in
                guard element.traits[OutlineLevelTraitKey.self] == nil else { return element }
                var copy = element
                copy.traits[OutlineLevelTraitKey.self] = depth
                return copy
            }
        }
        return _ViewListOutputs(list: ViewList(nodes: [.nested(.index(0), ViewList(element: labelElement)), .nested(.index(1), children)]))
    }
}

struct _StyledDisclosureGroup<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let isExpanded: Binding<Bool>

    var body: some View {
        _StyledView(configuration: DisclosureGroupStyleConfiguration(label: _StyleContent(label), content: _StyleContent(content), isExpanded: isExpanded)) {
            AnyView(AutomaticDisclosureGroupStyle().makeBody(configuration: $0))
        }
    }
}

/// Views that are transparent inside a List's rows (their children become rows) and a leading
/// stack elsewhere (OutlineGroup).
struct _OutlineRowsOrStack<Content: View>: View {
    let content: Content
    var body: Never { primitiveBody(Self.self) }

    var stack: VStack<Content> { VStack(alignment: .leading, spacing: 4) { content } }

    static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        VStack<Content>._makeView(view: view.project(inputs) { $0.stack }, inputs: inputs)
    }

    static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        guard inputs.outlineLevel != nil else { return .unary(view: view, inputs: inputs) }
        return Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs)
    }
}

extension DisclosureGroup where Label == Text {
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, content: content) { Text(title) }
    }

    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

struct SearchFocusRequestKey: EnvironmentKey { static let defaultValue: FocusRequest? = nil }

extension EnvironmentValues {
    var searchFocusRequest: FocusRequest? {
        get { self[SearchFocusRequestKey.self] }
        set { self[SearchFocusRequestKey.self] = newValue }
    }
}

/// The searchable field (picks up `searchFocused`).
struct _SearchFieldInput: View {
    let prompt: String
    let text: Binding<String>
    @Environment(\.searchFocusRequest) private var focus

    var body: some View {
        TextField(prompt, text: text).textFieldStyle(.plain)
            .environment(\.focusRequest, focus)
            .environment(\.submitTrigger, .search)
    }
}
