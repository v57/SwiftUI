#if canImport(AppKit)
import AppKit
import SwiftUI2Core

// MARK: - NSViewRepresentable

public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    public let coordinator: Representable.Coordinator
    public var transaction: Transaction
    public var environment: EnvironmentValues
}

/// Mirrors `SwiftUI.NSViewRepresentable`.
@MainActor @preconcurrency
public protocol NSViewRepresentable: View where Body == Never {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    typealias Context = NSViewRepresentableContext<Self>

    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize?
}

extension NSViewRepresentable where Coordinator == Void {
    public func makeCoordinator() {}
}

extension NSViewRepresentable {
    public static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {}
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSViewType, context: Context) -> CGSize? { nil }
    public var body: Never { fatalError("NSViewRepresentable has no body") }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        _makePlatformViewHost(view: view, inputs: inputs, make: { value, environment, transaction in
            let coordinator = value.makeCoordinator()
            let context = Context(coordinator: coordinator, transaction: transaction, environment: environment)
            return NSViewProvider<Self>(view: value.makeNSView(context: context), coordinator: coordinator, representable: value, context: context)
        }, update: { provider, value, environment, transaction in
            let provider = provider as! NSViewProvider<Self>
            let context = Context(coordinator: provider.coordinator, transaction: transaction, environment: environment)
            provider.representable = value
            provider.context = context
            value.updateNSView(provider.view, context: context)
        })
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _ViewListOutputs.unaryElement(view: view, inputs: inputs)
    }
}

@MainActor
final class NSViewProvider<R: NSViewRepresentable>: _PlatformViewProvider {
    let view: R.NSViewType
    let coordinator: R.Coordinator
    var representable: R
    var context: R.Context

    init(view: R.NSViewType, coordinator: R.Coordinator, representable: R, context: R.Context) {
        self.view = view
        self.coordinator = coordinator
        self.representable = representable
        self.context = context
    }

    var platformView: AnyObject { view }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        if let size = representable.sizeThatFits(proposal, nsView: view, context: context) { return size }
        return measure(view, proposal)
    }

    func dismantle() { R.dismantleNSView(view, coordinator: coordinator) }
}

/// SwiftUI's default sizing of hosted AppKit views: intrinsic size where defined, otherwise the
/// proposal (10 when unspecified).
@MainActor
func measure(_ view: NSView, _ proposal: ProposedViewSize) -> CGSize {
    let intrinsic = view.intrinsicContentSize
    let width = intrinsic.width == NSView.noIntrinsicMetric ? (proposal.width ?? 10) : intrinsic.width
    let height = intrinsic.height == NSView.noIntrinsicMetric ? (proposal.height ?? 10) : intrinsic.height
    return CGSize(width: width.isFinite ? width : 10, height: height.isFinite ? height : 10)
}

// MARK: - NSViewControllerRepresentable

public struct NSViewControllerRepresentableContext<Representable: NSViewControllerRepresentable> {
    public let coordinator: Representable.Coordinator
    public var transaction: Transaction
    public var environment: EnvironmentValues
}

@MainActor @preconcurrency
public protocol NSViewControllerRepresentable: View where Body == Never {
    associatedtype NSViewControllerType: NSViewController
    associatedtype Coordinator = Void
    typealias Context = NSViewControllerRepresentableContext<Self>

    func makeNSViewController(context: Context) -> NSViewControllerType
    func updateNSViewController(_ nsViewController: NSViewControllerType, context: Context)
    static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
}

extension NSViewControllerRepresentable where Coordinator == Void {
    public func makeCoordinator() {}
}

extension NSViewControllerRepresentable {
    public static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator) {}
    public var body: Never { fatalError("NSViewControllerRepresentable has no body") }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        _makePlatformViewHost(view: view, inputs: inputs, make: { value, environment, transaction in
            let coordinator = value.makeCoordinator()
            let context = Context(coordinator: coordinator, transaction: transaction, environment: environment)
            return NSViewControllerProvider<Self>(controller: value.makeNSViewController(context: context), coordinator: coordinator)
        }, update: { provider, value, environment, transaction in
            let provider = provider as! NSViewControllerProvider<Self>
            value.updateNSViewController(provider.controller, context: Context(coordinator: provider.coordinator, transaction: transaction, environment: environment))
        })
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _ViewListOutputs.unaryElement(view: view, inputs: inputs)
    }
}

@MainActor
final class NSViewControllerProvider<R: NSViewControllerRepresentable>: _PlatformViewProvider {
    let controller: R.NSViewControllerType
    let coordinator: R.Coordinator

    init(controller: R.NSViewControllerType, coordinator: R.Coordinator) {
        self.controller = controller
        self.coordinator = coordinator
    }

    var platformView: AnyObject { controller.view }
    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { measure(controller.view, proposal) }
    func dismantle() { R.dismantleNSViewController(controller, coordinator: coordinator) }
}

// MARK: - NSHostingController

/// `NSHostingController` equivalent (a view controller whose view is a SwiftUI2 hierarchy).
@MainActor
open class NSHostingController<Content: View>: NSViewController {
    private let content: Content

    public init(rootView: Content) {
        self.content = rootView
        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override func loadView() {
        view = NSHostingView(rootView: content)
    }
}
#endif

#if canImport(AppKit)
// MARK: - NSApplicationDelegateAdaptor

/// Mirrors `SwiftUI.NSApplicationDelegateAdaptor`: creates the delegate once and lets the app runner
/// forward `NSApplicationDelegate` messages it doesn't handle itself.
@MainActor @propertyWrapper
public struct NSApplicationDelegateAdaptor<DelegateType: NSObject & NSApplicationDelegate> {
    public let wrappedValue: DelegateType

    public init(_ delegateType: DelegateType.Type = DelegateType.self) {
        if let existing = AppKitAppRunner.userDelegate as? DelegateType {
            wrappedValue = existing
        } else {
            let delegate = delegateType.init()
            AppKitAppRunner.userDelegate = delegate
            wrappedValue = delegate
        }
    }
}

extension NSApplicationDelegateAdaptor where DelegateType: ObservableObject {
    public var projectedValue: ObservedObject<DelegateType>.Wrapper { ObservedObject(wrappedValue: wrappedValue).projectedValue }
}
#endif

#if canImport(AppKit)
// MARK: - Images from AppKit / Core Graphics

extension Image {
    public init(nsImage: NSImage) {
        self.init(_platformImage: PlatformImage(object: nsImage, size: nsImage.size))
    }

    public init(_ cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up, label: Text) {
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        self.init(_platformImage: PlatformImage(object: cgImage, size: size))
    }

    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Image.Orientation = .up) {
        let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        self.init(_platformImage: PlatformImage(object: cgImage, size: size))
    }
}
#endif

#if canImport(AppKit)
// MARK: - Colors from / to AppKit

extension Color {
    public init(_ nsColor: NSColor) { self.init(nsColor: nsColor) }

    /// A color from an AppKit color; dynamic system colors keep their light and dark values.
    public init(nsColor: NSColor) {
        func resolve(_ name: NSAppearance.Name) -> Color.Resolved {
            var resolved = Color.Resolved(red: 0, green: 0, blue: 0, opacity: 1)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let rgb = nsColor.usingColorSpace(.sRGB) ?? .black
                resolved = Color.Resolved(red: Float(rgb.redComponent), green: Float(rgb.greenComponent), blue: Float(rgb.blueComponent), opacity: Float(rgb.alphaComponent))
            }
            return resolved
        }
        self.init(_light: resolve(.aqua), dark: resolve(.darkAqua))
    }
}

extension NSColor {
    /// An AppKit color for a SwiftUI2 color (resolved for the current appearance).
    public convenience init(_ color: Color) {
        var environment = EnvironmentValues()
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        environment.colorScheme = isDark ? .dark : .light
        let resolved = color.resolve(in: environment)
        self.init(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }
}
#endif

#if canImport(AppKit)
extension View {
    /// AppKit content types (`.password`, `.username`, `.oneTimeCode`).
    /// Autofill hints for text fields (username, password, one-time code, ...).
    public func textContentType(_ type: NSTextContentType?) -> some View { environment(\._textContentType, type?.rawValue) }
}
#endif

#if canImport(AppKit)
/// Reads AppKit's attributed-string keys for `Text(AttributedString)`.
enum AppKitTextAttributeBridge {
    static func install() {
        TextAttributes.platformBridge = { substring in
            var styles: [TextAttributes.PlatformStyle] = []
            let runs = substring.runs
            guard let run = runs.first else { return styles }
            if run[SwiftUI2TextAttributes.UnderlineStyleAttribute.self] != nil || run[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] != nil { styles.append(.underline) }
            if run[SwiftUI2TextAttributes.StrikethroughStyleAttribute.self] != nil || run[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self] != nil { styles.append(.strikethrough) }
            if let tracking = run[SwiftUI2TextAttributes.TrackingAttribute.self] ?? run[SwiftUI2TextAttributes.KerningAttribute.self] ?? run[AttributeScopes.AppKitAttributes.TrackingAttribute.self] ?? run[AttributeScopes.AppKitAttributes.KernAttribute.self] { styles.append(.tracking(tracking)) }
            if let offset = run[SwiftUI2TextAttributes.BaselineOffsetAttribute.self] ?? run[AttributeScopes.AppKitAttributes.BaselineOffsetAttribute.self] { styles.append(.baselineOffset(offset)) }
            return styles
        }
    }
}
#endif

#if canImport(AppKit)
// MARK: - Attributed string keys that also exist in the SDK's SwiftUI scope

/// Declared here (a module importing AppKit) so they take precedence over the SDK's SwiftUI
/// attribute keys that AppKit makes visible but SwiftUI2 apps cannot link.
public enum SwiftUI2TextAttributes {
    public enum TrackingAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI2.Tracking" }
    public enum KerningAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI2.Kerning" }
    public enum BaselineOffsetAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI2.BaselineOffset" }
    public enum UnderlineStyleAttribute: AttributedStringKey { public typealias Value = Text.LineStyle; public static let name = "SwiftUI2.UnderlineStyle" }
    public enum StrikethroughStyleAttribute: AttributedStringKey { public typealias Value = Text.LineStyle; public static let name = "SwiftUI2.StrikethroughStyle" }
}

extension AttributeScopes {
    public struct SwiftUI2AppKitAttributes: AttributeScope {
        public let tracking: SwiftUI2TextAttributes.TrackingAttribute
        public let kern: SwiftUI2TextAttributes.KerningAttribute
        public let baselineOffset: SwiftUI2TextAttributes.BaselineOffsetAttribute
        public let underlineStyle: SwiftUI2TextAttributes.UnderlineStyleAttribute
        public let strikethroughStyle: SwiftUI2TextAttributes.StrikethroughStyleAttribute
        public let swiftUI2: SwiftUI2Attributes
    }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUI2AppKitAttributes, T>) -> T {
        self[T.self]
    }
}
#endif

#if canImport(AppKit)
extension Font {
    /// A font from an AppKit font (by name and size).
    public init(_ font: NSFont) {
        self = .custom(font.fontName, fixedSize: font.pointSize)
    }
}
#endif
