import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Style infrastructure

/// A type-erased style in the environment. Compared structurally, so a style whose parameters
/// change re-renders the views using it.
public struct _AnyStyle<Configuration>: @unchecked Sendable {
    let style: Any
    let make: @MainActor (Configuration) -> AnyView

    init(_ style: Any, make: @escaping @MainActor (Configuration) -> AnyView) {
        self.style = style
        self.make = make
    }
}

extension _AnyStyle: _GraphComparable {
    public static func _isIdentical(_ lhs: _AnyStyle, _ rhs: _AnyStyle) -> Bool { GraphComparison.compareAny(lhs.style, rhs.style) }
}

struct _StyleKey<Configuration>: EnvironmentKey {
    static var defaultValue: _AnyStyle<Configuration>? { nil }
}

extension EnvironmentValues {
    subscript<Configuration>(style configuration: Configuration.Type) -> _AnyStyle<Configuration>? {
        get { self[_StyleKey<Configuration>.self] }
        set { self[_StyleKey<Configuration>.self] = newValue }
    }
}

extension View {
    func _setStyle<Configuration>(_: Configuration.Type, _ style: _AnyStyle<Configuration>) -> some View {
        transformEnvironment(\.self) { $0[style: Configuration.self] = style }
    }
}

/// A style configuration's label or content (an erased view).
public struct _StyleContent: View {
    let content: AnyView
    init(_ content: some View) { self.content = AnyView(content) }
    public var body: some View { content }
}

extension _StyleContent: _MenuLabelConvertible {
    var _menuLabel: (String, String?) { MenuItems.title(of: content) }
}

/// Reads the style for `Configuration` from the environment and renders `configuration` with it
/// (or with `fallback` when no style was set).
struct _StyledView<Configuration>: View {
    let configuration: Configuration
    let fallback: @MainActor (Configuration) -> AnyView
    @Environment(\.self) private var environment

    var body: some View {
        if let style = environment[style: Configuration.self] {
            style.make(configuration)
        } else {
            fallback(configuration)
        }
    }
}

// MARK: - GroupBox

public struct GroupBoxStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
    public let label: Label
    public let content: Content
}

@MainActor @preconcurrency
public protocol GroupBoxStyle {
    associatedtype Body: View
    typealias Configuration = GroupBoxStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// macOS group box: a headline label over a rounded, tinted box.
public struct DefaultGroupBoxStyle: GroupBoxStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label.font(.headline)
            VStack(alignment: .leading) { configuration.content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
        }
    }
}

public typealias AutomaticGroupBoxStyle = DefaultGroupBoxStyle
extension GroupBoxStyle where Self == DefaultGroupBoxStyle { public static var automatic: DefaultGroupBoxStyle { .init() } }

extension View {
    public func groupBoxStyle<S: GroupBoxStyle>(_ style: S) -> some View {
        _setStyle(GroupBoxStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

// MARK: - LabeledContent

public struct LabeledContentStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
    public let label: Label
    public let content: Content
}

@MainActor @preconcurrency
public protocol LabeledContentStyle {
    associatedtype Body: View
    typealias Configuration = LabeledContentStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// Label then (secondary) value; in forms the value is pushed to the trailing edge.
public struct AutomaticLabeledContentStyle: LabeledContentStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _AutomaticLabeledContent(configuration: configuration) }
}

struct _AutomaticLabeledContent: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.isInForm) private var isInForm
    var body: some View {
        if isInForm, !labelsHidden {
            _FormLabeledRow { configuration.label } control: { configuration.content.foregroundStyle(.secondary) }
        } else {
            HStack(alignment: .firstTextBaseline) {
                if !labelsHidden { configuration.label }
                if isInForm { Spacer(minLength: 8) }
                configuration.content.foregroundStyle(.secondary)
            }
        }
    }
}

extension LabeledContentStyle where Self == AutomaticLabeledContentStyle { public static var automatic: AutomaticLabeledContentStyle { .init() } }

extension View {
    public func labeledContentStyle<S: LabeledContentStyle>(_ style: S) -> some View {
        _setStyle(LabeledContentStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

extension LabeledContent where Label == LabeledContentStyleConfiguration.Label, Content == LabeledContentStyleConfiguration.Content {
    /// Re-creates labeled content from a style configuration (inside custom styles).
    public init(_ configuration: LabeledContentStyleConfiguration) {
        self.init(content: { configuration.content }, label: { configuration.label })
    }
}

// MARK: - DisclosureGroup

public struct DisclosureGroupStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
    public let label: Label
    public let content: Content
    @Binding public var isExpanded: Bool
}

@MainActor @preconcurrency
public protocol DisclosureGroupStyle {
    associatedtype Body: View
    typealias Configuration = DisclosureGroupStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// A chevron button toggling indented content.
public struct AutomaticDisclosureGroupStyle: DisclosureGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let expanded = configuration.$isExpanded
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                }
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                VStack(alignment: .leading) { configuration.content }
                    .padding(.leading, 16)
            }
        }
    }
}

extension DisclosureGroupStyle where Self == AutomaticDisclosureGroupStyle { public static var automatic: AutomaticDisclosureGroupStyle { .init() } }

extension View {
    public func disclosureGroupStyle<S: DisclosureGroupStyle>(_ style: S) -> some View {
        _setStyle(DisclosureGroupStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

// MARK: - ProgressView

public struct ProgressViewStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias CurrentValueLabel = _StyleContent
    public let fractionCompleted: Double?
    public var label: Label?
    public var currentValueLabel: CurrentValueLabel?
}

@MainActor @preconcurrency
public protocol ProgressViewStyle {
    associatedtype Body: View
    typealias Configuration = ProgressViewStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

public struct LinearProgressViewStyle: ProgressViewStyle {
    public init() {}
    public init(tint: Color) {}
    public func makeBody(configuration: Configuration) -> some View { _DefaultProgressView(configuration: configuration, circular: false) }
}

public struct CircularProgressViewStyle: ProgressViewStyle {
    public init() {}
    public init(tint: Color) {}
    public func makeBody(configuration: Configuration) -> some View { _DefaultProgressView(configuration: configuration, circular: true) }
}

/// macOS: determinate progress is a bar, indeterminate a spinner.
public struct DefaultProgressViewStyle: ProgressViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { _DefaultProgressView(configuration: configuration, circular: false) }
}

extension ProgressViewStyle where Self == LinearProgressViewStyle { public static var linear: LinearProgressViewStyle { .init() } }
extension ProgressViewStyle where Self == CircularProgressViewStyle { public static var circular: CircularProgressViewStyle { .init() } }
extension ProgressViewStyle where Self == DefaultProgressViewStyle { public static var automatic: DefaultProgressViewStyle { .init() } }

struct _DefaultProgressView: View {
    let configuration: ProgressViewStyleConfiguration
    let circular: Bool
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let small = controlSize == .small || controlSize == .mini
        VStack(alignment: .leading, spacing: 4) {
            if let label = configuration.label { label }
            if let fraction = configuration.fractionCompleted, !circular {
                _LinearProgressBar(fraction: fraction, height: small ? 12 : 18)
            } else if let fraction = configuration.fractionCompleted {
                _CircularProgress(fraction: fraction, size: small ? 16 : 32)
            } else {
                _Spinner(size: small ? 16 : 32)
            }
            if let currentValueLabel = configuration.currentValueLabel { currentValueLabel.font(.caption).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    public func progressViewStyle<S: ProgressViewStyle>(_ style: S) -> some View {
        _setStyle(ProgressViewStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

extension ProgressView where Label == ProgressViewStyleConfiguration.Label, CurrentValueLabel == ProgressViewStyleConfiguration.CurrentValueLabel {
    /// Re-creates a progress view from a style configuration (inside custom styles).
    public init(_ configuration: ProgressViewStyleConfiguration) {
        self.init(fraction: configuration.fractionCompleted, label: configuration.label, currentValueLabel: configuration.currentValueLabel)
    }
}

// MARK: - Gauge

public struct GaugeStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias CurrentValueLabel = _StyleContent
    public typealias MarkedValueLabel = _StyleContent
    public typealias MinimumValueLabel = _StyleContent
    public typealias MaximumValueLabel = _StyleContent
    /// The value's position in the gauge's range, 0...1.
    public var value: Double
    public var label: Label
    public var currentValueLabel: CurrentValueLabel?
    public var minimumValueLabel: MinimumValueLabel?
    public var maximumValueLabel: MaximumValueLabel?
}

@MainActor @preconcurrency
public protocol GaugeStyle {
    associatedtype Body: View
    typealias Configuration = GaugeStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// Label and current value over a bar, with optional range labels.
public struct DefaultGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                configuration.label
                Spacer()
                if let current = configuration.currentValueLabel { current.foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                if let minimum = configuration.minimumValueLabel { minimum.font(.caption).foregroundStyle(.secondary) }
                _LinearProgressBar(fraction: configuration.value)
                if let maximum = configuration.maximumValueLabel { maximum.font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

public typealias LinearCapacityGaugeStyle = AccessoryLinearCapacityGaugeStyle

/// A thin capacity bar under the label.
public struct AccessoryLinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            configuration.label.font(.caption)
            _LinearProgressBar(fraction: configuration.value, height: 6)
        }
    }
}

/// A bar with a marker at the value.
public struct AccessoryLinearGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if let minimum = configuration.minimumValueLabel { minimum.font(.caption) }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4)
                    Circle().fill(Color.primary).frame(width: 8, height: 8)
                        .offset(x: max(0, min(1, configuration.value)) * max(0, proxy.size.width - 8))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 8)
            if let maximum = configuration.maximumValueLabel { maximum.font(.caption) }
        }
    }
}

/// A ring with the current value in the middle.
public struct AccessoryCircularCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ZStack {
            _CircularProgress(fraction: configuration.value, size: 44)
            configuration.currentValueLabel?.font(.caption)
        }
    }
}

/// An open ring (gap at the bottom) with a marker at the value.
public struct AccessoryCircularGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().trim(from: 0.125, to: 0.875).stroke(Color.secondary.opacity(0.3), lineWidth: 4).rotationEffect(.degrees(90))
            Circle().trim(from: 0.125, to: 0.125 + 0.75 * max(0, min(1, configuration.value))).stroke(Color.accentColor, lineWidth: 4).rotationEffect(.degrees(90))
            configuration.currentValueLabel?.font(.caption)
        }
        .frame(width: 44, height: 44)
    }
}

extension GaugeStyle where Self == DefaultGaugeStyle { public static var automatic: DefaultGaugeStyle { .init() } }
extension GaugeStyle where Self == AccessoryLinearCapacityGaugeStyle {
    public static var linearCapacity: AccessoryLinearCapacityGaugeStyle { .init() }
    public static var accessoryLinearCapacity: AccessoryLinearCapacityGaugeStyle { .init() }
}
extension GaugeStyle where Self == AccessoryLinearGaugeStyle { public static var accessoryLinear: AccessoryLinearGaugeStyle { .init() } }
extension GaugeStyle where Self == AccessoryCircularGaugeStyle { public static var accessoryCircular: AccessoryCircularGaugeStyle { .init() } }
extension GaugeStyle where Self == AccessoryCircularCapacityGaugeStyle { public static var accessoryCircularCapacity: AccessoryCircularCapacityGaugeStyle { .init() } }

extension View {
    public func gaugeStyle<S: GaugeStyle>(_ style: S) -> some View {
        _setStyle(GaugeStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

// MARK: - ControlGroup

public struct ControlGroupStyleConfiguration {
    public typealias Content = _StyleContent
    public typealias Label = _StyleContent
    public let content: Content
    public let label: Label
}

@MainActor @preconcurrency
public protocol ControlGroupStyle {
    associatedtype Body: View
    typealias Configuration = ControlGroupStyleConfiguration
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

/// Adjacent bordered buttons.
public struct AutomaticControlGroupStyle: ControlGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) { configuration.content }.buttonStyle(.bordered)
    }
}

/// Back/forward style navigation controls.
public struct NavigationControlGroupStyle: ControlGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) { configuration.content }.buttonStyle(.borderless).labelStyle(.iconOnly)
    }
}

/// Borderless controls in a row (menus show them as a palette).
public struct PaletteControlGroupStyle: ControlGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.content }.buttonStyle(.borderless).labelStyle(.iconOnly)
    }
}

/// The controls in a menu labeled with the group's label.
public struct MenuControlGroupStyle: ControlGroupStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Menu { configuration.content } label: { configuration.label }
    }
}

public typealias CompactMenuControlGroupStyle = MenuControlGroupStyle

extension ControlGroupStyle where Self == AutomaticControlGroupStyle { public static var automatic: AutomaticControlGroupStyle { .init() } }
extension ControlGroupStyle where Self == NavigationControlGroupStyle { public static var navigation: NavigationControlGroupStyle { .init() } }
extension ControlGroupStyle where Self == PaletteControlGroupStyle { public static var palette: PaletteControlGroupStyle { .init() } }
extension ControlGroupStyle where Self == MenuControlGroupStyle {
    public static var menu: MenuControlGroupStyle { .init() }
    public static var compactMenu: MenuControlGroupStyle { .init() }
}

extension View {
    public func controlGroupStyle<S: ControlGroupStyle>(_ style: S) -> some View {
        _setStyle(ControlGroupStyleConfiguration.self, _AnyStyle(style) { AnyView(style.makeBody(configuration: $0)) })
    }
}

extension ControlGroup where Content == ControlGroupStyleConfiguration.Content {
    public init(_ configuration: ControlGroupStyleConfiguration) {
        self.init(_content: configuration.content, label: configuration.label)
    }
}

// MARK: - TextEditor

public enum TextEditorStyleKind: Hashable, Sendable { case automatic, plain }

public protocol TextEditorStyle { var _kind: TextEditorStyleKind { get } }
public struct AutomaticTextEditorStyle: TextEditorStyle { public init() {}; public var _kind: TextEditorStyleKind { .automatic } }
public struct PlainTextEditorStyle: TextEditorStyle { public init() {}; public var _kind: TextEditorStyleKind { .plain } }
extension TextEditorStyle where Self == AutomaticTextEditorStyle { public static var automatic: AutomaticTextEditorStyle { .init() } }
extension TextEditorStyle where Self == PlainTextEditorStyle { public static var plain: PlainTextEditorStyle { .init() } }

struct TextEditorStyleKey: EnvironmentKey { static let defaultValue = TextEditorStyleKind.automatic }
extension EnvironmentValues {
    var textEditorStyle: TextEditorStyleKind {
        get { self[TextEditorStyleKey.self] }
        set { self[TextEditorStyleKey.self] = newValue }
    }
}

extension View {
    /// `.plain` removes the editor's bezel and background.
    public func textEditorStyle<S: TextEditorStyle>(_ style: S) -> some View { environment(\.textEditorStyle, style._kind) }
}

// MARK: - TabView

public enum TabViewStyleKind: Hashable, Sendable { case automatic, grouped, tabBarOnly, sidebarAdaptable }

public protocol TabViewStyle { var _kind: TabViewStyleKind { get } }
public struct DefaultTabViewStyle: TabViewStyle { public init() {}; public var _kind: TabViewStyleKind { .automatic } }
public struct GroupedTabViewStyle: TabViewStyle { public init() {}; public var _kind: TabViewStyleKind { .grouped } }
public struct TabBarOnlyTabViewStyle: TabViewStyle { public init() {}; public var _kind: TabViewStyleKind { .tabBarOnly } }
public struct SidebarAdaptableTabViewStyle: TabViewStyle { public init() {}; public var _kind: TabViewStyleKind { .sidebarAdaptable } }
extension TabViewStyle where Self == DefaultTabViewStyle { public static var automatic: DefaultTabViewStyle { .init() } }
extension TabViewStyle where Self == GroupedTabViewStyle { public static var grouped: GroupedTabViewStyle { .init() } }
extension TabViewStyle where Self == TabBarOnlyTabViewStyle { public static var tabBarOnly: TabBarOnlyTabViewStyle { .init() } }
extension TabViewStyle where Self == SidebarAdaptableTabViewStyle { public static var sidebarAdaptable: SidebarAdaptableTabViewStyle { .init() } }

struct TabViewStyleKey: EnvironmentKey { static let defaultValue = TabViewStyleKind.automatic }
extension EnvironmentValues {
    var tabViewStyle: TabViewStyleKind {
        get { self[TabViewStyleKey.self] }
        set { self[TabViewStyleKey.self] = newValue }
    }
}

extension View {
    /// `.sidebarAdaptable` lists the tabs in a sidebar; `.grouped` centers the tab bar.
    public func tabViewStyle<S: TabViewStyle>(_ style: S) -> some View { environment(\.tabViewStyle, style._kind) }
}

// MARK: - NavigationSplitView

public enum NavigationSplitViewStyleKind: Hashable, Sendable { case automatic, balanced, prominentDetail }

/// How split view columns share space. On macOS columns sit side by side for every style
/// (overlaying columns are an iPad behavior), so the style is recorded only.
public protocol NavigationSplitViewStyle { var _kind: NavigationSplitViewStyleKind { get } }
public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {}; public var _kind: NavigationSplitViewStyleKind { .automatic } }
public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {}; public var _kind: NavigationSplitViewStyleKind { .balanced } }
public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle { public init() {}; public var _kind: NavigationSplitViewStyleKind { .prominentDetail } }
extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle { public static var automatic: AutomaticNavigationSplitViewStyle { .init() } }
extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle { public static var balanced: BalancedNavigationSplitViewStyle { .init() } }
extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle { public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { .init() } }

struct NavigationSplitViewStyleKey: EnvironmentKey { static let defaultValue = NavigationSplitViewStyleKind.automatic }
extension EnvironmentValues {
    var navigationSplitViewStyle: NavigationSplitViewStyleKind {
        get { self[NavigationSplitViewStyleKey.self] }
        set { self[NavigationSplitViewStyleKey.self] = newValue }
    }
}

extension View {
    public func navigationSplitViewStyle<S: NavigationSplitViewStyle>(_ style: S) -> some View { environment(\.navigationSplitViewStyle, style._kind) }
}
