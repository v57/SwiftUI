import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Modifiers that are platform hints or iOS/visionOS-oriented on macOS are accepted without effect;
// the ones with visible behavior on macOS (inspector, onOpenURL, backgroundStyle, ...) are
// implemented.

public enum SymbolVariableValueMode: Sendable { case color, draw }
public enum SymbolColorRenderingMode: Sendable { case flat, gradient }
public enum ContentMarginPlacement: Sendable { case automatic, scrollContent, scrollIndicators }
public enum HoverEffect: Sendable { case automatic, highlight, lift }
public enum BadgeProminence: Sendable { case standard, increased, decreased }
/// The shape of bordered buttons' bezels.
public struct ButtonBorderShape: Hashable, Sendable {
    public enum _Kind: Hashable, Sendable { case automatic, capsule, circle, roundedRectangle(CGFloat?) }
    public let _kind: _Kind
    public static let automatic = ButtonBorderShape(_kind: .automatic)
    public static let capsule = ButtonBorderShape(_kind: .capsule)
    public static let circle = ButtonBorderShape(_kind: .circle)
    public static let roundedRectangle = ButtonBorderShape(_kind: .roundedRectangle(nil))
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { ButtonBorderShape(_kind: .roundedRectangle(radius)) }
}

/// How buttons size themselves (`.flexible` fills the proposed width).
public struct ButtonSizing: Hashable, Sendable {
    let value: Int
    public static let automatic = ButtonSizing(value: 0)
    public static let flexible = ButtonSizing(value: 1)
    public static let fitted = ButtonSizing(value: 2)
}

struct ButtonBorderShapeKey: EnvironmentKey { static let defaultValue = ButtonBorderShape.automatic }
struct ButtonSizingKey: EnvironmentKey { static let defaultValue = ButtonSizing.automatic }

extension EnvironmentValues {
    public var buttonBorderShape: ButtonBorderShape {
        get { self[ButtonBorderShapeKey.self] }
        set { self[ButtonBorderShapeKey.self] = newValue }
    }
    var _buttonSizing: ButtonSizing {
        get { self[ButtonSizingKey.self] }
        set { self[ButtonSizingKey.self] = newValue }
    }
}
public enum ButtonRepeatBehavior: Sendable { case automatic, enabled, disabled }
public enum SpringLoadingBehavior: Sendable { case automatic, enabled, disabled }
public enum TextScale: Sendable { case `default`, secondary }
public enum Prominence: Sendable { case standard, increased }
public enum ScrollEdgeEffectStyle: Sendable { case automatic, hard, soft }
public enum InspectorPlacement: Sendable { case automatic }

extension View {
    public func typesettingLanguage(_ language: Locale.Language, isEnabled: Bool = true) -> some View { self }
    public func toolbarTitleMenu<C: View>(@ViewBuilder content: () -> C) -> some View { self }
    public func labelsVisibility(_ visibility: Visibility) -> some View { environment(\.labelsHidden, visibility == .hidden) }
    public func allowsTightening(_ flag: Bool) -> some View { environment(\.allowsTightening, flag) }
    public func invalidatableContent(_ invalidatable: Bool = true) -> some View { self }
    public func handlesExternalEvents(preferring: Set<String>, allowing: Set<String>) -> some View { self }
    public func userActivity(_ activityType: String, isActive: Bool = true, _ update: @escaping (NSUserActivity) -> Void) -> some View { self }
    public func onContinueUserActivity(_ activityType: String, perform action: @escaping (NSUserActivity) -> Void) -> some View { self }
    public func hoverEffect(_ effect: HoverEffect = .automatic, isEnabled: Bool = true) -> some View { self }
    public func hoverEffectDisabled(_ disabled: Bool = true) -> some View { self }
    public func indexViewStyle<S>(_ style: S) -> some View { self }
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View { environment(\.buttonBorderShape, shape) }
    public func buttonSizing(_ sizing: ButtonSizing) -> some View { environment(\._buttonSizing, sizing) }
    /// Held buttons repeat their action (`.enabled`).
    public func buttonRepeatBehavior(_ behavior: ButtonRepeatBehavior) -> some View {
        environment(\._buttonRepeats, behavior == .enabled)
    }
    public func springLoadingBehavior(_ behavior: SpringLoadingBehavior) -> some View { self }
    public func textScale(_ scale: TextScale, isEnabled: Bool = true) -> some View { self }
    /// Radio-group pickers lay their options out in a row.
    public func horizontalRadioGroupLayout() -> some View { environment(\._horizontalRadioGroup, true) }
    public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View { self }
    public func backgroundExtensionEffect() -> some View { self }
    public func flipsForRightToLeftLayoutDirection(_ enabled: Bool) -> some View { self }
    public func symbolVariableValueMode(_ mode: SymbolVariableValueMode?) -> some View { self }
    public func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?) -> some View { self }

    /// The style `.background` / `BackgroundStyle` resolves to inside this view.
    public func backgroundStyle<S: ShapeStyle>(_ style: S) -> some View {
        environment(\.backgroundStyle, AnyShapeStyle(style))
    }

    /// A trailing inspector column (macOS shows it beside the content).
    public func inspector<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> V) -> some View {
        modifier(_InspectorModifier(isPresented: isPresented, inspector: content()))
    }

    /// The inspector column's width (applied to the inspector's content).
    public func inspectorColumnWidth(_ width: CGFloat) -> some View {
        preference(key: InspectorWidthKey.self, value: width)
    }

    public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        preference(key: InspectorWidthKey.self, value: ideal)
    }

    /// An async refresh action for the content (`\.refresh`; lists offer it to the user).
    public func refreshable(action: @escaping @Sendable () async -> Void) -> some View {
        environment(\.refresh, RefreshAction(action: action))
    }

    /// Sizes the view relative to its container (approximated by filling the offered space).
    public func containerRelativeFrame(_ axes: Axis.Set, alignment: Alignment = .center) -> some View {
        frame(maxWidth: axes.contains(.horizontal) ? .infinity : nil, maxHeight: axes.contains(.vertical) ? .infinity : nil, alignment: alignment)
    }

    public func containerRelativeFrame(_ axes: Axis.Set, count: Int, span: Int = 1, spacing: CGFloat, alignment: Alignment = .center) -> some View {
        containerRelativeFrame(axes, alignment: alignment)
    }

    public func containerRelativeFrame(_ axes: Axis.Set, alignment: Alignment = .center, _ length: @escaping (CGFloat, Axis) -> CGFloat) -> some View {
        containerRelativeFrame(axes, alignment: alignment)
    }

    /// URLs opened in the app (Finder, `open`, custom schemes) while this view is in a window.
    public func onOpenURL(perform action: @escaping @MainActor (URL) -> Void) -> some View {
        modifier(_OpenURLHandlerModifier(action: action))
    }
}

struct _SplitDividerLine: View {
    var body: some View { Rectangle().fill(Color.splitDivider).frame(width: 1) }
}

struct BackgroundStyleKey: EnvironmentKey { static let defaultValue: AnyShapeStyle? = nil }

extension EnvironmentValues {
    public var backgroundStyle: AnyShapeStyle? {
        get { self[BackgroundStyleKey.self] }
        set { self[BackgroundStyleKey.self] = newValue }
    }
}

/// Registers an `onOpenURL` handler while the view is on screen.
struct _OpenURLHandlerModifier: ViewModifier {
    let action: @MainActor (URL) -> Void
    @State private var token = _OpenURLToken()

    func body(content: Content) -> some View {
        token.action = action
        let token = self.token
        return content
            .onAppear { AppRuntime.urlHandlers.append(token) }
            .onDisappear { AppRuntime.urlHandlers.removeAll { $0 === token } }
    }
}

@MainActor
final class _OpenURLToken {
    var action: (@MainActor (URL) -> Void)?
}

extension AppRuntime {
    /// Live `onOpenURL` handlers (the backend delivers opened URLs to them).
    static var urlHandlers: [_OpenURLToken] = []

    /// Delivers URLs opened in the app; returns false if no view handles them.
    @discardableResult
    public static func handleOpenURLs(_ urls: [URL]) -> Bool {
        guard !urlHandlers.isEmpty else { return false }
        for url in urls { for handler in urlHandlers { handler.action?(url) } }
        return true
    }
}

struct HorizontalRadioGroupKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var _horizontalRadioGroup: Bool {
        get { self[HorizontalRadioGroupKey.self] }
        set { self[HorizontalRadioGroupKey.self] = newValue }
    }
}

struct ButtonRepeatsKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var _buttonRepeats: Bool {
        get { self[ButtonRepeatsKey.self] }
        set { self[ButtonRepeatsKey.self] = newValue }
    }
}

struct InspectorWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// The inspector column: 270pt unless its content sets `inspectorColumnWidth`.
struct _InspectorModifier<Inspector: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let inspector: Inspector
    @State private var width: CGFloat?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented.wrappedValue {
                _SplitDividerLine()
                inspector
                    .onPreferenceChange(InspectorWidthKey.self) { width = $0 }
                    .frame(width: width ?? 270)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing))
            }
        }
    }
}

/// Refreshes content (`refreshable`); call it as a function: `await refresh?()`.
public struct RefreshAction: @unchecked Sendable {
    let action: @Sendable () async -> Void
    public func callAsFunction() async { await action() }
}

struct RefreshActionKey: EnvironmentKey { static let defaultValue: RefreshAction? = nil }

extension EnvironmentValues {
    public var refresh: RefreshAction? {
        get { self[RefreshActionKey.self] }
        set { self[RefreshActionKey.self] = newValue }
    }
}
