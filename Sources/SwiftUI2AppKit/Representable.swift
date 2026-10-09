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
