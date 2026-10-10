#if os(Linux)
import Foundation
import CGtk3
import SwiftUI2Core

/// GTK 3 render backend: one `GtkNode` per platform render node, painted with cairo into the
/// host's drawing area (frames come from SwiftUI2's layout; text is measured and drawn with
/// Pango). Controls are drawn with the GTK theme's renderers; text fields become native entries
/// while they are edited.
@MainActor
public final class GtkBackend: RenderBackend {
    let root = GtkNode()
    weak var host: GtkHost?
    /// Nodes whose content changed this commit (native widgets to refresh).
    private var changed: Set<ObjectIdentifier> = []

    public var rootHandle: AnyObject { root }

    init() {
        GtkText.install()
    }

    // MARK: Rendering

    public func makeView(for node: RenderNode) -> AnyObject {
        let view = GtkNode()
        view.node = node
        view.content = node.content
        view.frame = node.frame
        view.presentation = node.presentation
        contentDidChange(view)
        return view
    }

    public func updateContent(of view: AnyObject, node: RenderNode) {
        let view = view as! GtkNode
        view.content = node.content
        GtkDebug.log("content \(view.kindName): \(node.content)".prefix(160).description, level: 3)
        contentDidChange(view)
    }

    private func contentDidChange(_ view: GtkNode) {
        changed.insert(ObjectIdentifier(view))
        host?.contentDidChange(view)
    }

    public func setFrame(of view: AnyObject, node: RenderNode) {
        (view as! GtkNode).frame = node.frame
        host?.setNeedsDisplay()
    }

    public func setPresentation(of view: AnyObject, node: RenderNode) {
        (view as! GtkNode).presentation = node.presentation
        host?.setNeedsDisplay()
    }

    public func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) {
        let view = view as! GtkNode
        let newChildren = children.map { $0 as! GtkNode }
        if newChildren.count == view.children.count, zip(newChildren, view.children).allSatisfy({ $0 === $1 }) { return }
        for child in view.children where child.parent === view && !newChildren.contains(where: { $0 === child }) {
            child.parent = nil
            host?.nodeRemoved(child)
        }
        for child in newChildren { child.parent = view }
        view.children = newChildren
        host?.setNeedsDisplay()
    }

    public func didCommit() {
        changed.removeAll()
        host?.didCommit()
    }

    // MARK: Metrics

    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        GtkText.measure(text, proposal: proposal)
    }

    public func unroundedTextWidth(_ text: ResolvedText) -> CGFloat {
        GtkText.metrics(text, width: nil).size.width
    }

    public func firstBaseline(of text: ResolvedText) -> CGFloat {
        GtkText.metrics(text, width: nil).baseline
    }

    public func imageSize(_ image: ResolvedImage) -> CGSize {
        switch image.source {
        case .system:
            let side = SymbolFont.glyphSize(image).rounded()
            return CGSize(width: side, height: side)
        case .named(let name):
            return GtkImages.load(named: name)?.size ?? CGSize(width: image.pointSize, height: image.pointSize)
        case .platform(let platform):
            return platform.size
        }
    }

    public func controlMetrics(_ control: ControlKind) -> ControlMetrics {
        GtkTheme.controlMetrics(control)
    }

    // MARK: Platform services

    public func openURL(_ url: URL) {
        var error: UnsafeMutablePointer<GError>?
        let window = host.flatMap { sui_window(raw($0.window)) }
        gtk_show_uri_on_window(window, url.absoluteString, guint32(GDK_CURRENT_TIME), &error)
        if let error { g_error_free(error) }
    }

    public func writeToPasteboard(_ items: [Any]) {
        let text = items.compactMap { item -> String? in
            if let string = item as? String { return string }
            if let url = item as? URL { return url.isFileURL ? url.path : url.absoluteString }
            if let attributed = item as? AttributedString { return String(attributed.characters) }
            return nil
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        let clipboard = gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0))
        gtk_clipboard_set_text(clipboard, text, -1)
    }

    public func readPasteboard() -> [NSItemProvider] {
        let clipboard = gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0))
        guard let text = gtk_clipboard_wait_for_text(clipboard) else { return [] }
        defer { g_free(text) }
        return [NSItemProvider(object: String(cString: text) as NSString)]
    }

    public func share(_ items: [Any]) {
        // No system share sheet on GTK: copy the items (like "Copy Link").
        writeToPasteboard(items)
    }

    public func decodeImage(_ data: Data, scale: CGFloat) -> PlatformImage? {
        guard let pixbuf = GtkImages.decode(data) else { return nil }
        let scale = max(scale, 0.01)
        let size = pixbuf.size
        return PlatformImage(object: pixbuf, size: CGSize(width: size.width / scale, height: size.height / scale))
    }

    public func presentFileDialog(_ request: FileDialogRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        GtkDialogs.presentFileDialog(request, parent: host?.window, completion: completion)
    }
}
#endif
