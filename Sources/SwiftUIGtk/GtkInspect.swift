#if os(Linux)
import CGtk3
import Foundation
import Glibc
import _SwiftUICore

/// The element channel on GTK (`_Inspection`): with `SWIFTUI_INSPECT=1`, a Unix socket in the user's runtime
/// directory, named after the process, answers `elements` with every window's visible elements: the header bar's
/// buttons, then the content's nodes as `_Inspection.decide` names them, at their window rects in pixels from the top-
/// left of what shows of the window (no client-side shadow), as an X capture of the window shows them.
enum GtkInspect {
    nonisolated(unsafe) private static var socketPath: [CChar] = []

    static func startIfRequested() {
        guard _Inspection.isEnabled else { return }
        let path = _Inspection.endpoint(pid: getpid())
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        socketPath = bytes
        atexit { GtkInspect.socketPath.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) } }
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                serve(client)
                close(client)
            }
        }
        thread.name = "SwiftUI element channel"
        thread.start()
    }

    /// One request per connection: a line, answered with one line of JSON.
    private static func serve(_ client: Int32) {
        var request = [UInt8]()
        var byte: UInt8 = 0
        while request.count < 256, read(client, &byte, 1) == 1, byte != 0x0A { request.append(byte) }
        let command = String(decoding: request, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let answer: Data
        if command == "elements" {
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                box.data = MainActor.assumeIsolated { _Inspection.encode(windows()) }
                done.signal()
            }
            answer = done.wait(timeout: .now() + 3) == .success ? box.data : Data("{\"error\":\"busy\"}\n".utf8)
        } else {
            answer = Data("{\"error\":\"unknown request\"}\n".utf8)
        }
        answer.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    @MainActor static func windows() -> [_InspectedWindow] {
        var windows: [_InspectedWindow] = []
        for controller in GtkAppRunner.controllers {
            guard gtk_widget_get_visible(controller.window) != 0 else { continue }
            let frame = controller.visibleFrame
            let scale = Double(gtk_widget_get_scale_factor(controller.window))
            var elements: [_InspectedElement] = []
            func add(role: String, label: String, value: String, rect: CGRect, depth: Int, enabled: Bool) {
                elements.append(
                    _InspectedElement(
                        role: role, label: label, value: value, x: Double(rect.minX) * scale, y: Double(rect.minY) * scale,
                        width: Double(rect.width) * scale, height: Double(rect.height) * scale, depth: depth, enabled: enabled))
            }
            GtkScript.visitWidgets(controller.headerBar) { @MainActor widget in
                guard gtk_widget_is_visible(widget) != 0,
                    g_type_check_instance_is_a(UnsafeMutablePointer(OpaquePointer(widget)), gtk_button_get_type()) != 0
                else { return }
                let label = gtk_button_get_label(sui_button(raw(widget))).map { String(cString: $0) } ?? ""
                let tip = gtk_widget_get_tooltip_text(widget).map { pointer in
                    defer { g_free(pointer) }
                    return String(cString: pointer)
                } ?? ""
                var x: Int32 = 0, y: Int32 = 0
                gtk_widget_translate_coordinates(widget, controller.window, 0, 0, &x, &y)
                let rect = CGRect(
                    x: CGFloat(x) - frame.minX, y: CGFloat(y) - frame.minY, width: CGFloat(gtk_widget_get_allocated_width(widget)),
                    height: CGFloat(gtk_widget_get_allocated_height(widget)))
                add(role: "button", label: label.isEmpty ? tip : label, value: "", rect: rect, depth: 0, enabled: gtk_widget_get_sensitive(widget) != 0)
            }
            for host in GtkHost.all where gtk_widget_get_toplevel(host.widget) == controller.window && gtk_widget_get_mapped(host.drawingArea) != 0 {
                var x: Int32 = 0, y: Int32 = 0
                gtk_widget_translate_coordinates(host.drawingArea, controller.window, 0, 0, &x, &y)
                let origin = CGPoint(x: CGFloat(x) - frame.minX, y: CGFloat(y) - frame.minY)
                let nodes = host.backend.root.descendants
                func visit(_ node: GtkNode, depth: Int) {
                    let visible = node.windowRect().visible
                    guard visible.width >= 1, visible.height >= 1, host.isVisible(node) else { return }
                    let decision = _Inspection.decide(
                        node.content, accessibility: node.node?.accessibility, hasPrimaryAction: node.actions.primary != nil,
                        descendantText: { text(under: node) })
                    switch decision {
                    case .hidden: return
                    case .pass:
                        for child in node.children { visit(child, depth: depth) }
                    case .element(let role, var label, let value, let leaf):
                        if label.isEmpty, case .textField = node.content { label = GtkScript.formLabel(of: node, among: nodes) ?? "" }
                        add(role: role, label: label, value: value, rect: visible.offsetBy(dx: origin.x, dy: origin.y), depth: depth, enabled: node.isEnabled)
                        if !leaf { for child in node.children { visit(child, depth: depth + 1) } }
                    }
                }
                for child in host.backend.root.children { visit(child, depth: 0) }
            }
            windows.append(
                _InspectedWindow(
                    title: controller.currentTitle, id: xid(of: controller.window), width: Double(frame.width) * scale,
                    height: Double(frame.height) * scale, scale: scale, elements: elements))
        }
        return windows
    }

    /// The texts under a node, in order: a button's or toggle's label.
    @MainActor private static func text(under node: GtkNode) -> String {
        var parts: [String] = []
        func visit(_ node: GtkNode) {
            if case .text(let text) = node.content { parts.append(text.string) }
            if let label = node.node?.accessibility?.label, !label.isEmpty {
                parts.append(label)
                return
            }
            for child in node.children where parts.count < 8 { visit(child) }
        }
        for child in node.children { visit(child) }
        return parts.joined(separator: " ")
    }

    /// The X window id of a toplevel on X11; nil on Wayland.
    @MainActor private static func xid(of window: UnsafeMutablePointer<GtkWidget>) -> UInt64? {
        guard let gdkWindow = gtk_widget_get_window(window),
            g_type_check_instance_is_a(UnsafeMutablePointer<GTypeInstance>(gdkWindow), gdk_x11_window_get_type()) != 0
        else { return nil }
        return UInt64(gdk_x11_window_get_xid(gdkWindow))
    }
}

@_silgen_name("gdk_x11_window_get_type")
private func gdk_x11_window_get_type() -> GType
@_silgen_name("gdk_x11_window_get_xid")
private func gdk_x11_window_get_xid(_ window: OpaquePointer?) -> UInt
#endif
