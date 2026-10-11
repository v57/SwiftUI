import Foundation
import Observation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Presentation appearance (from the presented content)

/// How a sheet is sized (`presentationSizing`).
public struct PresentationSizing: Hashable, Sendable {
    let minimumSize: CGSize
    let idealSize: CGSize?
    public static let automatic = PresentationSizing(minimumSize: CGSize(width: 320, height: 160), idealSize: nil)
    /// A standard form sheet.
    public static let form = PresentationSizing(minimumSize: CGSize(width: 500, height: 300), idealSize: CGSize(width: 580, height: 500))
    /// A large, document-like sheet.
    public static let page = PresentationSizing(minimumSize: CGSize(width: 600, height: 420), idealSize: CGSize(width: 800, height: 700))
    /// Exactly the content's size.
    public static let fitted = PresentationSizing(minimumSize: .zero, idealSize: nil)

    public func fitted(horizontal: Bool, vertical: Bool) -> PresentationSizing {
        PresentationSizing(minimumSize: CGSize(width: horizontal ? 0 : minimumSize.width, height: vertical ? 0 : minimumSize.height), idealSize: idealSize)
    }
    public func sticky(horizontal: Bool = false, vertical: Bool = false) -> PresentationSizing { self }
}

/// What a sheet's content asks of its presentation.
public struct PresentationAppearance: Equatable, @unchecked Sendable {
    public var background: AnyShapeStyle?
    public var cornerRadius: CGFloat?
    public var sizing = PresentationSizing.automatic
    public var isInteractiveDismissDisabled = false
    /// Presents a confirmation instead of dismissing interactively.
    public var dismissConfirmation: (@MainActor () -> Void)?

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cornerRadius == rhs.cornerRadius && lhs.sizing == rhs.sizing && lhs.isInteractiveDismissDisabled == rhs.isInteractiveDismissDisabled
            && (lhs.dismissConfirmation == nil) == (rhs.dismissConfirmation == nil)
            && GraphComparison.isIdentical(lhs.background, rhs.background)
    }
}

public struct PresentationAppearanceKey: PreferenceKey {
    public static var defaultValue: PresentationAppearance { PresentationAppearance() }
    public static func reduce(value: inout PresentationAppearance, nextValue: () -> PresentationAppearance) {
        let next = nextValue()
        value.background = next.background ?? value.background
        value.cornerRadius = next.cornerRadius ?? value.cornerRadius
        if next.sizing != .automatic { value.sizing = next.sizing }
        value.isInteractiveDismissDisabled = value.isInteractiveDismissDisabled || next.isInteractiveDismissDisabled
        value.dismissConfirmation = next.dismissConfirmation ?? value.dismissConfirmation
    }
}

extension View {
    func _presentationAppearance(_ edit: @escaping (inout PresentationAppearance) -> Void) -> some View {
        transformPreference(PresentationAppearanceKey.self, edit)
    }

    public func presentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        _presentationAppearance { $0.background = AnyShapeStyle(style) }
    }

    public func presentationBackground<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        background(alignment: alignment, content: content)._presentationAppearance { $0.background = AnyShapeStyle(Color.clear) }
    }

    public func presentationCornerRadius(_ radius: CGFloat?) -> some View { _presentationAppearance { $0.cornerRadius = radius } }
    public func presentationSizing(_ sizing: PresentationSizing) -> some View { _presentationAppearance { $0.sizing = sizing } }

    /// Escape and clicks outside don't dismiss the sheet.
    public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View {
        _presentationAppearance { $0.isInteractiveDismissDisabled = $0.isInteractiveDismissDisabled || isDisabled }
    }

    /// Dismissing the sheet interactively (or closing the window) asks for confirmation first.
    @_disfavoredOverload public func dismissalConfirmationDialog<S: StringProtocol, A: View>(_ title: S, shouldPresent: Bool, @ViewBuilder actions: @escaping () -> A) -> some View {
        modifier(_DismissalConfirmationModifier(title: Text(title), message: nil, shouldPresent: shouldPresent, actions: { AnyView(actions()) }))
    }

    @_disfavoredOverload public func dismissalConfirmationDialog<S: StringProtocol, A: View, M: View>(_ title: S, shouldPresent: Bool, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        let text = message()
        return modifier(_DismissalConfirmationModifier(title: Text(title), message: AnyView(text), shouldPresent: shouldPresent, actions: { AnyView(actions()) }))
    }

    public func dismissalConfirmationDialog<A: View>(_ title: Text, shouldPresent: Bool, @ViewBuilder actions: @escaping () -> A) -> some View {
        modifier(_DismissalConfirmationModifier(title: title, message: nil, shouldPresent: shouldPresent, actions: { AnyView(actions()) }))
    }

    // iOS sheet behaviors without a macOS counterpart (sheets are window-modal panels).
    public func presentationBackgroundInteraction(_ interaction: PresentationBackgroundInteraction) -> some View { self }
    public func presentationCompactAdaptation(_ adaptation: PresentationAdaptation) -> some View { self }
    public func presentationCompactAdaptation(horizontal: PresentationAdaptation, vertical: PresentationAdaptation) -> some View { self }
    public func presentationContentInteraction(_ behavior: PresentationContentInteraction) -> some View { self }
}

public struct PresentationBackgroundInteraction: Sendable {
    public static let automatic = PresentationBackgroundInteraction()
    public static let enabled = PresentationBackgroundInteraction()
    public static let disabled = PresentationBackgroundInteraction()
    public static func enabled(upThrough detent: PresentationDetent) -> PresentationBackgroundInteraction { .enabled }
}

public enum PresentationAdaptation: Sendable { case automatic, none, popover, sheet, fullScreenCover }
public enum PresentationContentInteraction: Sendable { case automatic, resizes, scrolls }

struct _DismissalConfirmationModifier: ViewModifier {
    let title: Text
    let message: AnyView?
    let shouldPresent: Bool
    let actions: () -> AnyView
    @State private var isShowing = false

    func body(content: Content) -> some View {
        let showing = $isShowing
        let shouldPresent = self.shouldPresent
        let message = self.message
        content
            .confirmationDialog(title.plainString, isPresented: showing, actions: actions) { message ?? AnyView(EmptyView()) }
            ._presentationAppearance { if shouldPresent { $0.dismissConfirmation = { showing.wrappedValue = true } } }
            ._windowConfiguration { if shouldPresent { $0.closeConfirmation = { showing.wrappedValue = true } } }
    }
}

// MARK: - Dialog details

public enum DialogSeverity: Hashable, Sendable { case automatic, critical, standard }

struct DialogIconKey: EnvironmentKey { static var defaultValue: Image? { nil } }
struct DialogSeverityKey: EnvironmentKey { static let defaultValue = DialogSeverity.automatic }
struct DialogSuppressionKey: EnvironmentKey { static var defaultValue: (label: Text, binding: Binding<Bool>)? { nil } }

extension EnvironmentValues {
    var dialogIcon: Image? {
        get { self[DialogIconKey.self] }
        set { self[DialogIconKey.self] = newValue }
    }
    var dialogSeverity: DialogSeverity {
        get { self[DialogSeverityKey.self] }
        set { self[DialogSeverityKey.self] = newValue }
    }
    var dialogSuppression: (label: Text, binding: Binding<Bool>)? {
        get { self[DialogSuppressionKey.self] }
        set { self[DialogSuppressionKey.self] = newValue }
    }
}

extension View {
    /// The icon of alerts and confirmation dialogs presented from this view.
    public func dialogIcon(_ icon: Image?) -> some View { environment(\.dialogIcon, icon) }
    /// `.critical` alerts show a caution badge.
    public func dialogSeverity(_ severity: DialogSeverity) -> some View { environment(\.dialogSeverity, severity) }
    /// A "Do not show this message again" checkbox in the dialog.
    public func dialogSuppressionToggle(isSuppressed: Binding<Bool>) -> some View {
        environment(\.dialogSuppression, (Text("Do not show this message again"), isSuppressed))
    }
    @_disfavoredOverload public func dialogSuppressionToggle<S: StringProtocol>(_ title: S, isSuppressed: Binding<Bool>) -> some View {
        environment(\.dialogSuppression, (Text(title), isSuppressed))
    }
    public func dialogSuppressionToggle(_ label: Text, isSuppressed: Binding<Bool>) -> some View {
        environment(\.dialogSuppression, (label, isSuppressed))
    }
    public func dialogPreventsAppTermination(_ prevents: Bool?) -> some View { self }
    public func presentationPreventsAppTermination(_ prevents: Bool?) -> some View { self }
}

/// Observable holder of a presentation's appearance.
@Observable
@MainActor
final class _PresentationAppearanceBox {
    var appearance = PresentationAppearance()
}
