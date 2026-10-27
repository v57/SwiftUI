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
    /// A `TextEditor` (the canvas draws it scrolled while it isn't edited; see `GtkTextArea`).
    private let isTextArea: Bool
    private var field: ResolvedTextField
    /// The selection last reported to or taken from the binding (UTF-16 offsets).
    private var knownSelection: Range<Int>?
    /// The gutter's width (`textEditorLineNumbers`), 0 without one.
    private var gutterWidth: CGFloat = 0

    init(host: GtkHost, node: GtkNode, field: ResolvedTextField) {
        self.host = host
        self.node = node
        self.field = field
        isMultiline = field.isMultiline || field.wraps
        isTextArea = field.isTextArea
        knownSelection = field.selection
        if isMultiline {
            let view = gtk_text_view_new()!
            gtk_text_view_set_wrap_mode(sui_text_view(raw(view)), GTK_WRAP_WORD_CHAR)
            // Unhinted metrics, as the canvas lays text out: lines keep their height when editing starts.
            let options = cairo_font_options_create()
            if let screen = gdk_screen_get_default(), let screenOptions = gdk_screen_get_font_options(screen) {
                cairo_font_options_merge(options, screenOptions)
            }
            cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
            gtk_widget_set_font_options(view, options)
            cairo_font_options_destroy(options)
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
            if isTextArea {
                let cursorMoved: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
                    MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).selectionChanged() }
                }
                connect(UnsafeMutableRawPointer(buffer), "notify::cursor-position", data, cursorMoved)
                let markSet: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, _, data in
                    MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).selectionChanged() }
                }
                connect(UnsafeMutableRawPointer(buffer), "mark-set", data, markSet)
                // The line numbers, after the text view drew its windows.
                let draw: @convention(c) (UnsafeMutableRawPointer?, Cairo?, UnsafeMutableRawPointer?) -> gboolean = { _, cr, data in
                    guard let cr else { return 0 }
                    MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).drawGutter(cr) }
                    return 0
                }
                g_signal_connect_data(raw(textView), "draw", unsafeBitCast(draw, to: GCallback.self), data, nil, GConnectFlags(rawValue: 1)) // G_CONNECT_AFTER
            }
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
            if isTextArea {
                applyGutter(field)
                // A selection the binding set (not one the text view reported) moves the caret.
                if let selection = field.selection, selection != knownSelection, selection != currentSelection {
                    select(selection, in: buffer)
                }
                knownSelection = field.selection
            }
        }
        self.field = field
        gtk_widget_set_sensitive(focusWidget, field.isEnabled.gboolean)
        applyStyle(field)
    }

    // MARK: Text editors

    /// The text view's selection in UTF-16 offsets.
    private var currentSelection: Range<Int>? {
        guard let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) else { return nil }
        var insert = GtkTextIter(), bound = GtkTextIter(), start = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer))
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer))
        if gtk_text_iter_compare(&insert, &bound) > 0 { swap(&insert, &bound) }
        gtk_text_buffer_get_start_iter(buffer, &start)
        func utf16Length(_ from: inout GtkTextIter, _ to: inout GtkTextIter) -> Int {
            guard let chars = gtk_text_buffer_get_text(buffer, &from, &to, 1) else { return 0 }
            defer { g_free(chars) }
            return String(cString: chars).utf16.count
        }
        let lower = utf16Length(&start, &insert)
        return lower..<(lower + utf16Length(&insert, &bound))
    }

    /// Selects the UTF-16 offsets `range` and scrolls them into view.
    private func select(_ range: Range<Int>, in buffer: UnsafeMutablePointer<GtkTextBuffer>) {
        let text = self.text
        var lower = GtkTextIter(), upper = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &lower, gint(ResolvedTextField.characterOffset(ofUTF16: range.lowerBound, in: text)))
        gtk_text_buffer_get_iter_at_offset(buffer, &upper, gint(ResolvedTextField.characterOffset(ofUTF16: range.upperBound, in: text)))
        updating = true
        gtk_text_buffer_select_range(buffer, &lower, &upper)
        updating = false
        if let textView { gtk_text_view_scroll_to_mark(sui_text_view(raw(textView)), gtk_text_buffer_get_insert(buffer), 0.1, 0, 0, 0) }
    }

    /// The caret or selection moved: the binding follows (`TextEditor(text:selection:)`), the gutter's current line too.
    private func selectionChanged() {
        if let textView, gutterWidth > 0 { gtk_widget_queue_draw(textView) }
        guard !updating, field.tracksSelection, let selection = currentSelection, selection != knownSelection else { return }
        knownSelection = selection
        node?.actions.setSelection?(selection)
        host.flushSoon()
    }

    /// The line-number gutter's width for the text's line count (a border window at the text view's leading edge).
    private func applyGutter(_ field: ResolvedTextField) {
        guard let textView, let node else { return }
        let (gutter, insets) = node.textAreaGeometry(field)
        let view = sui_text_view(raw(textView))
        if gutter != gutterWidth {
            gutterWidth = gutter
            gtk_text_view_set_border_window_size(view, GTK_TEXT_WINDOW_LEFT, gint(gutter))
        }
        // The text where the canvas draws it.
        gtk_text_view_set_left_margin(view, gint(insets.leading - gutter))
        gtk_text_view_set_right_margin(view, gint(insets.trailing))
        gtk_text_view_set_top_margin(view, gint(insets.top))
        gtk_text_view_set_bottom_margin(view, gint(insets.bottom))
    }

    /// Draws the line numbers of the visible lines into the text view's leading border window.
    private func drawGutter(_ cr: Cairo) {
        guard gutterWidth > 0, let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) else { return }
        let view = sui_text_view(raw(textView))
        guard let window = gtk_text_view_get_window(view, GTK_TEXT_WINDOW_LEFT), gtk_cairo_should_draw_window(cr, window) != 0 else { return }
        cairo_save(cr)
        defer { cairo_restore(cr) }
        gtk_cairo_transform_to_window(cr, textView, window)
        var visible = GdkRectangle()
        gtk_text_view_get_visible_rect(view, &visible)
        var cursor = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer))
        let currentLine = gtk_text_iter_get_line(&cursor)
        let numbers = GtkLineNumbers(font: field.font)
        var iter = GtkTextIter()
        var lineTop: gint = 0
        gtk_text_view_get_line_at_y(view, &iter, visible.y, &lineTop)
        while true {
            var y: gint = 0, height: gint = 0
            gtk_text_view_get_line_yrange(view, &iter, &y, &height)
            if y > visible.y + visible.height { break }
            var windowY: gint = 0
            gtk_text_view_buffer_to_window_coords(view, GTK_TEXT_WINDOW_LEFT, 0, y, nil, &windowY)
            let line = gtk_text_iter_get_line(&iter)
            numbers.draw(
                Int(line) + 1, in: cr, rightEdge: gutterWidth, top: CGFloat(windowY), color: field.color,
                current: line == currentLine)
            if gtk_text_iter_forward_line(&iter) == 0 {
                // The last line, when the text ends with a newline, is empty and still numbered.
                if gtk_text_iter_get_line(&iter) != line {
                    continue
                }
                break
            }
        }
    }

    /// Places the caret at the character (Unicode scalar) `offset`.
    func placeCaret(atCharacter offset: Int) {
        guard let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) else { return }
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, gint(offset))
        updating = true
        gtk_text_buffer_place_cursor(buffer, &iter)
        updating = false
        selectionChanged()
    }

    /// Scrolls the text view to show what the canvas showed: the character (Unicode scalar) `offset`'s line
    /// `fraction` of the way down. GTK lays a long text out over many idles, the lines it hasn't laid out yet having
    /// no height, so the line's place is known once every line above is laid out. Until then the text view stays
    /// transparent and the canvas draws the text and the caret (typing goes to the text view all along).
    func scroll(toCharacter offset: Int, at fraction: CGFloat, contentHeight: CGFloat) {
        guard let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))) else { return }
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &iter, gint(offset))
        if let existing = gtk_text_buffer_get_mark(buffer, "swiftui-scroll") {
            gtk_text_buffer_move_mark(buffer, existing, &iter)
        } else {
            gtk_text_buffer_create_mark(buffer, "swiftui-scroll", &iter, 1)
        }
        scrollFraction = fraction
        expectedHeight = contentHeight
        settleDeadline = monotonicSeconds() + 8
        isSettling = true
        lastUpper = -1
        steadyPolls = 0
        gtk_widget_set_opacity(container, 0)
        let poll: @convention(c) (gpointer?) -> gboolean = { data in
            MainActor.assumeIsolated { object(data, as: GtkTextEditor.self).settlePoll() }.gboolean
        }
        settleSource = g_timeout_add_full(G_PRIORITY_DEFAULT, 50, poll, unretained(self), nil)
    }

    /// The text view is scrolling to what the canvas shows (the canvas still draws the text).
    private(set) var isSettling = false
    private var scrollFraction: CGFloat = 0
    /// The text's height as the canvas lays it out (the text view's, once it laid every line out).
    private var expectedHeight: CGFloat = 0
    private var settleDeadline: Double = 0
    private var settleSource: guint = 0
    private var lastUpper: Double = -1
    private var steadyPolls = 0

    /// Every 50 ms while settling: once GTK laid every line out (its height is the canvas's, or stopped growing),
    /// scrolls the mark's line to its place and shows the text view.
    private func settlePoll() -> Bool {
        guard isSettling, let textView, let buffer = gtk_text_view_get_buffer(sui_text_view(raw(textView))),
            let mark = gtk_text_buffer_get_mark(buffer, "swiftui-scroll")
        else {
            settleSource = 0
            return false
        }
        let adjustment = gtk_scrolled_window_get_vadjustment(sui_scrolled_window(raw(container)))
        let upper = gtk_adjustment_get_upper(adjustment)
        steadyPolls = upper == lastUpper ? steadyPolls + 1 : 0
        lastUpper = upper
        let laidOut = upper >= Double(expectedHeight) - 1 || steadyPolls >= 6
        guard laidOut || monotonicSeconds() > settleDeadline else { return true }
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &iter, mark)
        var rect = GdkRectangle()
        gtk_text_view_get_iter_location(sui_text_view(raw(textView)), &iter, &rect)
        let page = gtk_adjustment_get_page_size(adjustment)
        let value = Double(rect.y) - Double(scrollFraction) * (page - Double(rect.height))
        gtk_adjustment_set_value(adjustment, min(max(0, value), max(0, upper - page)))
        settleSource = 0
        finishSettling()
        return false
    }

    private func finishSettling() {
        guard isSettling else { return }
        isSettling = false
        if settleSource != 0 { g_source_remove(settleSource) }
        settleSource = 0
        gtk_widget_set_opacity(container, 1)
        host.setNeedsDisplay()
    }

    /// The character (Unicode scalar) offset where the paragraph at the top of the visible text starts, and how far
    /// above the top it starts.
    var topParagraph: (offset: Int, lineOffset: CGFloat)? {
        guard let textView else { return nil }
        let view = sui_text_view(raw(textView))
        var visible = GdkRectangle()
        gtk_text_view_get_visible_rect(view, &visible)
        var iter = GtkTextIter()
        var lineTop: gint = 0
        gtk_text_view_get_line_at_y(view, &iter, visible.y, &lineTop)
        return (Int(gtk_text_iter_get_offset(&iter)), CGFloat(visible.y - lineTop))
    }

    /// The text view's scroll offset.
    var scrollOffset: CGFloat {
        CGFloat(gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(sui_scrolled_window(raw(container)))))
    }

    /// The foreground runs the text view's tags show, and a tag per color.
    private var appliedRuns: [ResolvedTextField.ForegroundRun] = []
    /// The buffer's length when `appliedRuns` were applied.
    private var appliedCharCount = 0
    private var foregroundTags: [String: UnsafeMutablePointer<GtkTextTag>] = [:]

    /// Colors the text view's text as a styled `TextEditor`'s runs say.
    private func applyForeground(_ runs: [ResolvedTextField.ForegroundRun], to buffer: UnsafeMutablePointer<GtkTextBuffer>) {
        guard runs != appliedRuns else { return }
        // Only the runs that changed: those before the edit are the same, those after it moved by the edit's length
        // (the buffer moved their tags along), so a keystroke in a long file retags a few runs, not the file.
        let old = appliedRuns
        let count = Int(gtk_text_buffer_get_char_count(buffer))
        let delta = count - appliedCharCount
        appliedRuns = runs
        appliedCharCount = count
        var prefix = 0
        while prefix < old.count, prefix < runs.count, old[prefix] == runs[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < runs.count - prefix {
            let o = old[old.count - 1 - suffix], n = runs[runs.count - 1 - suffix]
            guard o.color == n.color, o.range.lowerBound + delta == n.range.lowerBound, o.range.upperBound + delta == n.range.upperBound else { break }
            suffix += 1
        }
        let changed = runs[prefix..<(runs.count - suffix)]
        let removed = old[prefix..<(old.count - suffix)]
        // The span the changed runs cover, before and after: its tags are replaced.
        let lowers = changed.map(\.range.lowerBound) + removed.map { min($0.range.lowerBound, $0.range.lowerBound + delta) }
        let uppers = changed.map(\.range.upperBound) + removed.map { max($0.range.upperBound, $0.range.upperBound + delta) }
        guard let low = lowers.min(), let high = uppers.max() else { return }
        var start = GtkTextIter(), end = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &start, gint(max(0, low)))
        gtk_text_buffer_get_iter_at_offset(buffer, &end, gint(min(count, high)))
        for tag in foregroundTags.values { gtk_text_buffer_remove_tag(buffer, tag, &start, &end) }
        for run in changed {
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
            css += " entry, text, border { border: none; box-shadow: none; outline: none; background: transparent; padding: 0; min-height: 0; }"
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
        // The caret moved with the edit; the selection is reported against the new text.
        if isTextArea {
            knownSelection = nil
            selectionChanged()
        }
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
        if settleSource != 0 { g_source_remove(settleSource) }
        settleSource = 0
        if let cssProvider { g_object_unref(UnsafeMutableRawPointer(cssProvider)) }
        cssProvider = nil
        gtk_widget_destroy(container)
    }
}
#endif
