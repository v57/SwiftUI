#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

// MARK: - GtkWidgetRepresentable

public struct GtkWidgetRepresentableContext<Representable: GtkWidgetRepresentable> {
    public let coordinator: Representable.Coordinator
    public var transaction: Transaction
    public var environment: EnvironmentValues
}

/// Not Apple API: a GTK widget in a SwiftUI hierarchy, the GTK backend's `NSViewRepresentable` (a web view, a video
/// sink's widget). The widget is a `GtkWidget *` passed as an `OpaquePointer`, so libraries with their own GTK
/// bindings (WebKitGTK's, GStreamer's) don't need this module's. The backend keeps a reference while it shows the
/// widget and places it over the canvas at the view's frame: it is drawn above everything SwiftUI draws (like a native
/// view on the other backends), hidden while scrolled out of sight or out of the hierarchy, and gets its own input.
@MainActor @preconcurrency
public protocol GtkWidgetRepresentable: View where Body == Never {
    associatedtype Coordinator = Void
    typealias Context = GtkWidgetRepresentableContext<Self>

    /// The widget (`GtkWidget *`), made once per identity. It may be one the app keeps and shows again later.
    func makeWidget(context: Context) -> OpaquePointer
    func updateWidget(_ widget: OpaquePointer, context: Context)
    static func dismantleWidget(_ widget: OpaquePointer, coordinator: Coordinator)
    func makeCoordinator() -> Coordinator
    /// The view's size for a proposal; nil takes the proposal (the widget's natural size where it's unspecified).
    func sizeThatFits(_ proposal: ProposedViewSize, widget: OpaquePointer, context: Context) -> CGSize?
}

extension GtkWidgetRepresentable where Coordinator == Void {
    public func makeCoordinator() {}
}

extension GtkWidgetRepresentable {
    public static func dismantleWidget(_ widget: OpaquePointer, coordinator: Coordinator) {}
    public func sizeThatFits(_ proposal: ProposedViewSize, widget: OpaquePointer, context: Context) -> CGSize? { nil }
    public var body: Never { fatalError("GtkWidgetRepresentable has no body") }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        _makePlatformViewHost(view: view, inputs: inputs, make: { value, environment, transaction in
            let coordinator = value.makeCoordinator()
            let context = Context(coordinator: coordinator, transaction: transaction, environment: environment)
            let widget = value.makeWidget(context: context)
            return GtkWidgetProvider<Self>(widget: GtkPlatformWidget(widget), coordinator: coordinator, representable: value, context: context)
        }, update: { provider, value, environment, transaction in
            let provider = provider as! GtkWidgetProvider<Self>
            let context = Context(coordinator: provider.coordinator, transaction: transaction, environment: environment)
            provider.representable = value
            provider.context = context
            value.updateWidget(provider.widget.pointer, context: context)
        })
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        _ViewListOutputs.unaryElement(view: view, inputs: inputs)
    }
}

@MainActor
final class GtkWidgetProvider<R: GtkWidgetRepresentable>: _PlatformViewProvider {
    let widget: GtkPlatformWidget
    let coordinator: R.Coordinator
    var representable: R
    var context: R.Context

    init(widget: GtkPlatformWidget, coordinator: R.Coordinator, representable: R, context: R.Context) {
        self.widget = widget
        self.coordinator = coordinator
        self.representable = representable
        self.context = context
    }

    var platformView: AnyObject { widget }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        if let size = representable.sizeThatFits(proposal, widget: widget.pointer, context: context) { return size }
        var natural = GtkRequisition()
        if proposal.width == nil || proposal.height == nil { gtk_widget_get_preferred_size(widget.widget, nil, &natural) }
        func finite(_ value: CGFloat?, _ fallback: gint) -> CGFloat {
            guard let value, value.isFinite else { return CGFloat(max(fallback, 10)) }
            return value
        }
        return CGSize(width: finite(proposal.width, natural.width), height: finite(proposal.height, natural.height))
    }

    func dismantle() {
        widget.isDismantled = true
        R.dismantleWidget(widget.pointer, coordinator: coordinator)
        GtkHost.all.forEach { $0.layoutPlatformWidgets() }
    }
}

/// A representable's widget as the render tree's platform view (the token's object), holding a reference to it.
@MainActor
final class GtkPlatformWidget {
    nonisolated(unsafe) let widget: UnsafeMutablePointer<GtkWidget>
    var isDismantled = false

    init(_ pointer: OpaquePointer) {
        widget = UnsafeMutablePointer<GtkWidget>(pointer)
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
    }

    var pointer: OpaquePointer { OpaquePointer(widget) }

    deinit {
        nonisolated(unsafe) let object = UnsafeMutableRawPointer(widget)
        DispatchQueue.main.async { g_object_unref(object) }
    }
}

// MARK: - Placement

/// The host's embedded widgets, by node.
@MainActor
struct GtkPlatformWidgets {
    struct Entry {
        weak var node: GtkNode?
        let widget: GtkPlatformWidget
    }
    var entries: [ObjectIdentifier: Entry] = [:]
}

extension GtkHost {
    /// A node's content changed: a platform view's widget is placed at the next layout.
    func platformContentDidChange(_ node: GtkNode) {
        let id = ObjectIdentifier(node)
        guard case .platformView(let token) = node.content, let widget = token.object as? GtkPlatformWidget else {
            if let entry = platformWidgets.entries.removeValue(forKey: id) { detach(entry.widget) }
            return
        }
        if let old = platformWidgets.entries[id], old.widget !== widget { detach(old.widget) }
        platformWidgets.entries[id] = .init(node: node, widget: widget)
    }

    /// Positions the embedded widgets over their nodes; widgets whose node left the tree come off the window.
    func layoutPlatformWidgets() {
        for (id, entry) in platformWidgets.entries {
            guard let node = entry.node, !entry.widget.isDismantled, isAttached(node) else {
                if entry.node == nil || entry.widget.isDismantled { platformWidgets.entries[id] = nil }
                detach(entry.widget)
                continue
            }
            let widget = entry.widget.widget
            let (rect, visible) = node.windowRect()
            if gtk_widget_get_parent(widget) == nil {
                gtk_fixed_put(sui_fixed(raw(fixed)), widget, 0, 0)
            }
            if visible.width < 1 || visible.height < 1 {
                gtk_widget_hide(widget)
                continue
            }
            gtk_fixed_move(sui_fixed(raw(fixed)), widget, Int32(rect.minX.rounded()), Int32(rect.minY.rounded()))
            gtk_widget_set_size_request(widget, Int32(max(1, rect.width.rounded())), Int32(max(1, rect.height.rounded())))
            gtk_widget_show(widget)
        }
    }

    private func isAttached(_ node: GtkNode) -> Bool {
        var current: GtkNode? = node
        while let next = current {
            if next === backend.root { return true }
            current = next.parent
        }
        return false
    }

    private func detach(_ widget: GtkPlatformWidget) {
        guard let parent = gtk_widget_get_parent(widget.widget), parent == fixed else { return }
        gtk_container_remove(sui_container(raw(fixed)), widget.widget)
    }
}
#endif
