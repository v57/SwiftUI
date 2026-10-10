import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Modifiers that are platform hints or iOS/visionOS-oriented on macOS are accepted without effect;
// the ones with visible behavior on macOS (inspector, onOpenURL, backgroundStyle, ...) are
// implemented.

public enum SymbolVariableValueMode: Sendable { case color, draw }
public enum SymbolColorRenderingMode: Sendable { case flat, gradient }
public enum SearchPresentationToolbarBehavior: Sendable { case automatic, avoidHidingContent }
public enum PresentationSizing: Sendable { case automatic, form, page, fitted }
public enum ContentMarginPlacement: Sendable { case automatic, scrollContent, scrollIndicators }
public enum DialogSeverity: Sendable { case automatic, critical, standard }
public enum WindowInteractionBehavior: Sendable { case automatic, enabled, disabled }
public enum HoverEffect: Sendable { case automatic, highlight, lift }
public enum BadgeProminence: Sendable { case standard, increased, decreased }
public enum ButtonBorderShape: Sendable {
    case automatic, capsule, circle, roundedRectangle
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { .roundedRectangle }
}
public enum ButtonRepeatBehavior: Sendable { case automatic, enabled, disabled }
public enum SpringLoadingBehavior: Sendable { case automatic, enabled, disabled }
public enum PointerStyle: Sendable { case `default`, link, grabIdle, grabActive, horizontalText, verticalText, columnResize, rowResize }
public enum TextScale: Sendable { case `default`, secondary }
public enum Prominence: Sendable { case standard, increased }
public enum ScrollEdgeEffectStyle: Sendable { case automatic, hard, soft }
public enum InspectorPlacement: Sendable { case automatic }
public struct SensoryFeedback: Sendable {
    public static let success = SensoryFeedback(), warning = SensoryFeedback(), error = SensoryFeedback(), selection = SensoryFeedback()
    public static let increase = SensoryFeedback(), decrease = SensoryFeedback(), start = SensoryFeedback(), stop = SensoryFeedback()
    public static let alignment = SensoryFeedback(), levelChange = SensoryFeedback(), pathComplete = SensoryFeedback()
    public static func impact(weight: Int = 0, intensity: Double = 1) -> SensoryFeedback { SensoryFeedback() }
}

extension View {
    public func searchPresentationToolbarBehavior(_ behavior: SearchPresentationToolbarBehavior) -> some View { self }
    public func searchSuggestions<S: View>(@ViewBuilder _ suggestions: () -> S) -> some View { self }
    public func searchScopes<V: Hashable, S: View>(_ scope: Binding<V>, @ViewBuilder scopes: () -> S) -> some View { self }
    public func searchCompletion<S: StringProtocol>(_ completion: S) -> some View { self }
    public func toolbarBackgroundVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func presentationBackground<S: ShapeStyle>(_ style: S) -> some View { self }
    public func presentationCornerRadius(_ radius: CGFloat?) -> some View { self }
    public func presentationSizing(_ sizing: PresentationSizing) -> some View { self }
    public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View { self }
    public func listRowSpacing(_ spacing: CGFloat?) -> some View { self }
    public func listSectionSpacing(_ spacing: CGFloat) -> some View { self }
    public func typesettingLanguage(_ language: Locale.Language, isEnabled: Bool = true) -> some View { self }
    public func focusSection() -> some View { self }
    public func prefersDefaultFocus(_ prefersDefaultFocus: Bool = true, in namespace: Namespace.ID) -> some View { self }
    public func dialogIcon(_ icon: Image?) -> some View { self }
    public func dialogSeverity(_ severity: DialogSeverity) -> some View { self }
    public func dialogSuppressionToggle(isSuppressed: Binding<Bool>) -> some View { self }
    public func fileDialogDefaultDirectory(_ url: URL?) -> some View { self }
    public func fileDialogMessage(_ message: Text?) -> some View { self }
    public func fileDialogConfirmationLabel(_ label: Text?) -> some View { self }
    public func windowDismissBehavior(_ behavior: WindowInteractionBehavior) -> some View { self }
    public func windowMinimizeBehavior(_ behavior: WindowInteractionBehavior) -> some View { self }
    public func windowResizeBehavior(_ behavior: WindowInteractionBehavior) -> some View { self }
    public func toolbarTitleMenu<C: View>(@ViewBuilder content: () -> C) -> some View { self }
    public func labelsVisibility(_ visibility: Visibility) -> some View { environment(\.labelsHidden, visibility == .hidden) }
    public func allowsTightening(_ flag: Bool) -> some View { self }
    public func invalidatableContent(_ invalidatable: Bool = true) -> some View { self }
    public func handlesExternalEvents(preferring: Set<String>, allowing: Set<String>) -> some View { self }
    public func userActivity(_ activityType: String, isActive: Bool = true, _ update: @escaping (NSUserActivity) -> Void) -> some View { self }
    public func onContinueUserActivity(_ activityType: String, perform action: @escaping (NSUserActivity) -> Void) -> some View { self }
    public func hoverEffect(_ effect: HoverEffect = .automatic, isEnabled: Bool = true) -> some View { self }
    public func hoverEffectDisabled(_ disabled: Bool = true) -> some View { self }
    public func controlGroupStyle<S>(_ style: S) -> some View { self }
    public func gaugeStyle<S>(_ style: S) -> some View { self }
    public func labeledContentStyle<S>(_ style: S) -> some View { self }
    public func groupBoxStyle<S>(_ style: S) -> some View { self }
    public func disclosureGroupStyle<S>(_ style: S) -> some View { self }
    public func navigationSplitViewStyle<S>(_ style: S) -> some View { self }
    public func tabViewStyle<S>(_ style: S) -> some View { self }
    public func indexViewStyle<S>(_ style: S) -> some View { self }
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View { self }
    public func buttonRepeatBehavior(_ behavior: ButtonRepeatBehavior) -> some View { self }
    public func springLoadingBehavior(_ behavior: SpringLoadingBehavior) -> some View { self }
    public func pointerStyle(_ style: PointerStyle?) -> some View { self }
    public func pointerVisibility(_ visibility: Visibility) -> some View { self }
    public func textScale(_ scale: TextScale, isEnabled: Bool = true) -> some View { self }
    public func headerProminence(_ prominence: Prominence) -> some View { self }
    public func badgeProminence(_ prominence: BadgeProminence) -> some View { self }
    public func listItemTint(_ tint: Color?) -> some View { self }
    public func listRowSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View { self }
    public func listSectionSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View { self }
    public func selectionDisabled(_ isDisabled: Bool = true) -> some View { self }
    public func horizontalRadioGroupLayout() -> some View { self }
    public func navigationDocument(_ url: URL) -> some View { self }
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
        let inspector = content()
        return HStack(spacing: 0) {
            self.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented.wrappedValue {
                _SplitDividerLine()
                inspector
                    .frame(width: 270)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    public func inspectorColumnWidth(_ width: CGFloat) -> some View { self }
    public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View { self }

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
