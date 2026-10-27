#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// A text field being edited: a native `GtkEntry` (or a `GtkTextView` for multi-line fields)
/// placed over the field's frame. Fields that aren't being edited are drawn on the canvas, so
/// native widgets never cover SwiftUI content such as sheets and menus.
@MainActor
final class GtkTextEditor {
    unowned let host: GtkHost
    weak var node: GtkNode?
    /// The widget added to the host's overlay (the entry, or a scrolled window with a text view).
    let container: UnsafeMutablePointer<GtkWidget>
    private let entry: UnsafeMutablePointer<GtkWidget>?
    private let textView: UnsafeMutablePointer<GtkWidget>?
    private var updating = false
    private var cssProvider: UnsafeMutablePointer<GtkCssProvider>?
    private(set) var isMultiline: Bool

    init(host: GtkHost, node: GtkNode, field: ResolvedTextField) {
        self.host = host
        self.node = node
        isMultiline = field.isMultiline || field.wraps
        if isMultiline {
            let view = gtk_text_view_new()!
            gtk_text_view_set_wrap_mode(sui_text_view(raw(view)), GTK_WRAP_WORD_CHAR)
            let scrolled = gtk_scrolled_window_new(nil, nil)!
            gtk_scrolled_window_set_policy(sui_scrolled_window(raw(scrolled)), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_container_add(sui_container(raw(scrolled)), view)
            if field.style != .plain {
                gtk_style_context_add_class(gtk_widget_get_style_context(scrolled), "frame")
                gtk_scrolled_window_set_shadow_type(sui_scrolled_window(raw(scrolled)), GTK_SHADOW_IN)
            }
            textView = view
            entry = nil
            container = scrolled
        } else {
            let entry = gtk_entry_new()!
            if field.style == .plain { gtk_entry_set_has_frame(sui_entry(raw(entry)), 0) }
            // The node's frame sets the width; don't impose GTK's minimum of ~20 characters.
            gtk_entry_set_width_chars(sui_entry(raw(entry)), 1)
            self.entry = entry
            textView = nil
            container = entry
        }
        let data = unretained(self)
        if let entry {
            let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
                MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).textChanged() }
            }
            connect(raw(entry), "changed", data, changed)
            let activate: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
                MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).submit() }
            }
            connect(raw(entry), "activate", data, activate)
        }
        if let textView {
            let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView)))
            let changed: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
                MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).textChanged() }
            }
            connect(UnsafeMutableRawPointer(buffer), "changed", data, changed)
        }
        let focusWidget = entry ?? textView!
        let focusOut: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, _, data in
            MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).focusLost() }
            return 0
        }
        connect(raw(focusWidget), "focus-out-event", data, focusOut)
        let key: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkEventKey>?, UnsafeMutableRawPointer?) -> gboolean = { _, event, data in
            guard let event else { return 0 }
            return MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).keyPressed(event.pointee) }.gboolean
        }
        connect(raw(focusWidget), "key-press-event", data, key)
        apply(field)
    }

    private var focusWidget: UnsafeMutablePointer<GtkWidget> { entry ?? textView! }

    /// Applies content changes from the graph (text, font, placeholder, ...).
    func apply(_ field: ResolvedTextField) {
        updating = true
        defer { updating = false }
        if let entry {
            let current = String(cString: gtk_entry_get_text(sui_entry(raw(entry))))
            if current != field.text { gtk_entry_set_text(sui_entry(raw(entry)), field.text) }
            gtk_entry_set_placeholder_text(sui_entry(raw(entry)), field.placeholder)
            gtk_entry_set_visibility(sui_entry(raw(entry)), (!field.isSecure).gboolean)
            let alignment: Float = field.alignment == .center ? 0.5 : field.alignment == .trailing ? 1 : 0
            gtk_entry_set_alignment(sui_entry(raw(entry)), alignment)
        }
        if let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) {
            if text != field.text {
                gtk_text_buffer_set_text(buffer, field.text, -1)
                appliedRuns = []
            }
            applyForeground(field.foregroundRuns, to: buffer)
        }
        gtk_widget_set_sensitive(focusWidget, field.isEnabled.gboolean)
        applyStyle(field)
    }

    /// The foreground runs the text view's tags show, and a tag per color.
    private var appliedRuns: [ResolvedTextField.ForegroundRun] = []
    private var foregroundTags: [String: UnsafeMutablePointer<GtkTextTag>] = [:]

    /// Colors the text view's text as a styled `TextEditor`'s runs say.
    private func applyForeground(_ runs: [ResolvedTextField.ForegroundRun], to buffer: UnsafeMutablePointer<GtkTextBuffer>) {
        guard runs != appliedRuns else { return }
        appliedRuns = runs
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        for tag in foregroundTags.values { gtk_text_buffer_remove_tag(buffer, tag, &start, &end) }
        for run in runs {
            let c = run.color
            let key = "\(c.red),\(c.green),\(c.blue),\(c.opacity)"
            let tag: UnsafeMutablePointer<GtkTextTag>
            if let existing = foregroundTags[key] {
                tag = existing
            } else {
                var rgba = GdkRGBA(red: Double(c.red), green: Double(c.green), blue: Double(c.blue), alpha: Double(c.opacity))
                tag = sui_text_buffer_foreground_tag(buffer, &rgba)
                foregroundTags[key] = tag
            }
            gtk_text_buffer_get_iter_at_offset(buffer, &start, gint(run.range.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &end, gint(run.range.upperBound))
            gtk_text_buffer_apply_tag(buffer, tag, &start, &end)
        }
    }

    /// Font and color of the field (CSS on the widget).
    private func applyStyle(_ field: ResolvedTextField) {
        let font = field.font
        let family = font.name ?? (font.design == .monospaced ? "monospace" : font.design == .serif ? "serif" : GtkText.systemFamily)
        let c = field.color
        let color = "rgba(\(Int(c.red * 255)),\(Int(c.green * 255)),\(Int(c.blue * 255)),\(c.opacity))"
        var css = """
        * { font-family: "\(family)"; font-size: \(font.size)px; font-weight: \(GtkText.cssWeight(font.weight)); \
        font-style: \(font.italic ? "italic" : "normal"); color: \(color); }
        """
        if field.style == .plain {
            // Plain fields edit in place: no bezel, the text where the canvas drew it.
            css += " entry, text { border: none; box-shadow: none; outline: none; background: transparent; padding: 0; min-height: 0; }"
        }
        if cssProvider == nil {
            cssProvider = gtk_css_provider_new()
            gtk_style_context_add_provider(gtk_widget_get_style_context(focusWidget), OpaquePointer(cssProvider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
        gtk_css_provider_load_from_data(cssProvider, css, -1, nil)
    }

    var text: String {
        if let entry { return String(cString: gtk_entry_get_text(sui_entry(raw(entry)))) }
        guard let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) else { return "" }
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let chars = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(chars) }
        return String(cString: chars)
    }

    /// Replaces the text as typing would (script mode): the change reaches the binding.
    func setText(_ text: String) {
        if let entry {
            gtk_entry_set_text(sui_entry(raw(entry)), text)
            gtk_editable_set_position(sui_editable(raw(entry)), -1)
        } else if let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) {
            gtk_text_buffer_set_text(buffer, text, -1)
        }
    }

    func focus() {
        gtk_widget_grab_focus(focusWidget)
        if let entry { gtk_editable_set_position(sui_editable(raw(entry)), -1) }
    }

    var hasFocus: Bool { gtk_widget_has_focus(focusWidget) != 0 }

    private func textChanged() {
        guard !updating else { return }
        node?.actions.setText?(text)
        host.flushSoon()
    }

    private func submit() {
        node?.actions.submit?()
        host.flushSoon()
    }

    private func keyPressed(_ event: GdkEventKey) -> Bool {
        if event.keyval == UInt32(GDK_KEY_Escape) {
            host.endEditing(commit: true)
            return true
        }
        if event.keyval == UInt32(GDK_KEY_Tab) || event.keyval == UInt32(GDK_KEY_ISO_Left_Tab) {
            let backwards = event.keyval == UInt32(GDK_KEY_ISO_Left_Tab) || (event.state & GDK_SHIFT_MASK.rawValue) != 0
            if !isMultiline || (event.state & GDK_CONTROL_MASK.rawValue) != 0 {
                host.focusNextField(from: node, backwards: backwards)
                return true
            }
        }
        return false
    }

    private func focusLost() {
        // Focus moving to a menu/popover of the same window keeps editing; otherwise end it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFocus else { return }
            self.host.endEditing(editor: self)
        }
    }

    func destroy() {
        if let cssProvider { g_object_unref(UnsafeMutableRawPointer(cssProvider)) }
        cssProvider = nil
        gtk_widget_destroy(container)
    }
}
#endif
