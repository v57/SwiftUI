#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// A multi-line text editor (`TextEditor`) drawn on the canvas while it isn't being edited: its text laid out once
/// (until the text, font, colors or width change), drawn from the editor's scroll offset one visible line at a time,
/// so a long file scrolls and redraws without laying out again, with the line-number gutter
/// (`textEditorLineNumbers`) the native text view shows while editing.
@MainActor
final class GtkTextArea {
    private struct Key: Equatable {
        var text: String
        var font: Font.Resolved
        var width: CGFloat
        var runs: [ResolvedTextField.ForegroundRun]
    }

    /// A visual line of the layout.
    struct Line {
        var line: UnsafeMutablePointer<PangoLayoutLine>
        /// Top and height in the layout, in points.
        var top: CGFloat
        var height: CGFloat
        /// Baseline from the layout's top.
        var baseline: CGFloat
        /// The paragraph (text line, from 0) the line belongs to.
        var paragraph: Int
        var startsParagraph: Bool
    }

    private var key: Key?
    nonisolated(unsafe) private var layout: OpaquePointer?
    private(set) var lines: [Line] = []
    /// The text's height.
    private(set) var height: CGFloat = 0
    private(set) var paragraphCount = 1

    deinit {
        if let layout { g_object_unref(UnsafeMutableRawPointer(layout)) }
    }

    /// Lays `field`'s text out for `width` points (text width, the gutter left out) unless it already is.
    func update(_ field: ResolvedTextField, width: CGFloat) {
        let key = Key(text: field.text, font: field.font, width: width, runs: field.foregroundRuns)
        guard key != self.key else { return }
        self.key = key
        if let layout { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let layout = pango_layout_new(GtkText.context)!
        self.layout = layout
        let description = GtkText.fontDescription(field.font)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, field.text, -1)
        if !field.foregroundRuns.isEmpty {
            let attributes = GtkText.foregroundAttributes(field.foregroundRuns, in: field.text)
            pango_layout_set_attributes(layout, attributes)
            pango_attr_list_unref(attributes)
        }
        pango_layout_set_width(layout, Int32(max(1, width) * CGFloat(PANGO_SCALE)))
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        lines.removeAll(keepingCapacity: true)
        let scale = CGFloat(PANGO_SCALE)
        let iter = pango_layout_get_iter(layout)!
        defer { pango_layout_iter_free(iter) }
        var paragraph = -1
        repeat {
            guard let line = pango_layout_iter_get_line_readonly(iter) else { continue }
            var y0: Int32 = 0, y1: Int32 = 0
            pango_layout_iter_get_line_yrange(iter, &y0, &y1)
            let starts = pango_layout_line_is_paragraph_start(line) != 0 || paragraph < 0
            if starts { paragraph += 1 }
            lines.append(Line(
                line: line, top: CGFloat(y0) / scale, height: CGFloat(y1 - y0) / scale,
                baseline: CGFloat(pango_layout_iter_get_baseline(iter)) / scale, paragraph: paragraph, startsParagraph: starts))
        } while pango_layout_iter_next_line(iter) != 0
        // Pango ends a text that ends with a newline with an empty line, as text views show it.
        paragraphCount = max(1, paragraph + 1)
        height = (lines.last.map { $0.top + $0.height } ?? 0).rounded(.up)
    }

    /// The character (Unicode scalar) offset of the text at `point` (layout coordinates).
    func characterOffset(at point: CGPoint) -> Int {
        guard let layout, let key else { return 0 }
        var index: Int32 = 0, trailing: Int32 = 0
        let scale = CGFloat(PANGO_SCALE)
        _ = pango_layout_xy_to_index(layout, Int32(point.x * scale), Int32(point.y * scale), &index, &trailing)
        let utf8 = key.text.utf8
        let byte = utf8.index(utf8.startIndex, offsetBy: min(max(0, Int(index)), utf8.count))
        let scalars = key.text.unicodeScalars
        let scalarIndex = byte.samePosition(in: scalars) ?? scalars.endIndex
        return scalars.distance(from: scalars.startIndex, to: scalarIndex) + Int(trailing)
    }

    /// The caret's rectangle before the character (Unicode scalar) `offset` (layout coordinates, zero width).
    func caretRect(ofCharacter offset: Int) -> CGRect {
        guard let layout, let key else { return .zero }
        let scalars = key.text.unicodeScalars
        let index = scalars.index(scalars.startIndex, offsetBy: min(max(0, offset), scalars.count))
        let byte = key.text.utf8.distance(from: key.text.utf8.startIndex, to: index)
        var rect = PangoRectangle()
        pango_layout_get_cursor_pos(layout, Int32(byte), &rect, nil)
        let scale = CGFloat(PANGO_SCALE)
        return CGRect(x: CGFloat(rect.x) / scale, y: CGFloat(rect.y) / scale, width: 0, height: CGFloat(rect.height) / scale)
    }

    /// The top of the line holding the character (Unicode scalar) `offset`, and its height (layout coordinates).
    func lineRect(ofCharacter offset: Int) -> (top: CGFloat, height: CGFloat) {
        guard let layout, let key else { return (0, 0) }
        let scalars = key.text.unicodeScalars
        let index = scalars.index(scalars.startIndex, offsetBy: min(max(0, offset), scalars.count))
        let byte = key.text.utf8.distance(from: key.text.utf8.startIndex, to: index)
        var rect = PangoRectangle()
        pango_layout_index_to_pos(layout, Int32(byte), &rect)
        let scale = CGFloat(PANGO_SCALE)
        return (CGFloat(rect.y) / scale, max(1, CGFloat(rect.height) / scale))
    }

    /// The first line starting at or below `y` (layout coordinates): its first character (a Unicode scalar offset),
    /// top and height.
    func lineTop(below y: CGFloat) -> (offset: Int, y: CGFloat, height: CGFloat) {
        guard !lines.isEmpty else { return (0, 0, 0) }
        var index = min(firstLine(below: y), lines.count - 1)
        if lines[index].top < y, index + 1 < lines.count { index += 1 }
        let line = lines[index]
        return (characterOffset(at: CGPoint(x: 0, y: line.top + line.height / 2)), line.top, line.height)
    }

    /// The first line at or below `y` (layout coordinates).
    private func firstLine(below y: CGFloat) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].top + lines[mid].height <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Draws the lines between `scroll` and `scroll + visibleHeight` at `origin` (the text's top left when unscrolled).
    func draw(in cr: Cairo, origin: CGPoint, scroll: CGFloat, visibleHeight: CGFloat, color: Color.Resolved, opacity: Double) {
        guard !lines.isEmpty else { return }
        color.set(cr, opacity: opacity)
        var index = firstLine(below: scroll)
        while index < lines.count, lines[index].top < scroll + visibleHeight {
            let line = lines[index]
            cairo_move_to(cr, Double(origin.x), Double(origin.y + line.baseline - scroll))
            pango_cairo_show_layout_line(cr, line.line)
            index += 1
        }
    }

    /// Draws the numbers of the paragraphs starting between `scroll` and `scroll + visibleHeight`.
    func drawLineNumbers(
        in cr: Cairo, font: Font.Resolved, gutterWidth: CGFloat, top: CGFloat, scroll: CGFloat, visibleHeight: CGFloat,
        color: Color.Resolved, currentLine: Int?
    ) {
        let numbers = GtkLineNumbers(font: font)
        var index = firstLine(below: scroll)
        while index < lines.count, lines[index].top < scroll + visibleHeight {
            let line = lines[index]
            if line.startsParagraph {
                numbers.draw(
                    line.paragraph + 1, in: cr, rightEdge: gutterWidth, baseline: top + line.baseline - scroll, color: color,
                    current: line.paragraph == currentLine)
            }
            index += 1
        }
    }
}

/// The line-number gutter of a text editor (`textEditorLineNumbers`), the same on the canvas and beside GTK's text view.
@MainActor
struct GtkLineNumbers {
    let font: Font.Resolved
    /// Space between the numbers and the text.
    static let trailingGap: CGFloat = 12
    static let leadingGap: CGFloat = 8

    private static var digitWidths: [Font.Resolved: CGFloat] = [:]

    /// The gutter's width for `lineCount` lines (at least three digits, so it rarely grows while typing).
    static func width(font: Font.Resolved, lineCount: Int) -> CGFloat {
        let digits = max(3, String(max(1, lineCount)).count)
        return (CGFloat(digits) * digitWidth(GtkLineNumbers(font: font).numberFont) + leadingGap + trailingGap).rounded(.up)
    }

    private static func digitWidth(_ font: Font.Resolved) -> CGFloat {
        if let width = digitWidths[font] { return width }
        let layout = pango_layout_new(GtkText.context)!
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let description = GtkText.fontDescription(font)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, "0000000000", -1)
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        let width = CGFloat(logical.width) / CGFloat(PANGO_SCALE) / 10
        digitWidths[font] = width
        return width
    }

    /// The numbers' font: the text's, with tabular digits.
    var numberFont: Font.Resolved { font }

    /// Draws `number` right-aligned at `rightEdge - trailingGap` on `baseline` (or with its top at `top`).
    func draw(_ number: Int, in cr: Cairo, rightEdge: CGFloat, baseline: CGFloat? = nil, top: CGFloat = 0, color: Color.Resolved, current: Bool) {
        let layout = pango_cairo_create_layout(cr)!
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let description = GtkText.fontDescription(numberFont)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, String(number), -1)
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        let width = CGFloat(logical.width) / CGFloat(PANGO_SCALE)
        let ascent = CGFloat(pango_layout_get_baseline(layout)) / CGFloat(PANGO_SCALE)
        cairo_move_to(cr, Double(rightEdge - Self.trailingGap - width), Double(baseline.map { $0 - ascent } ?? top))
        color.set(cr, opacity: current ? 0.85 : 0.4)
        pango_cairo_show_layout(cr, layout)
    }
}

extension ResolvedTextField {
    /// A `TextEditor` (not a vertical text field): drawn by `GtkTextArea`, scrolled by the backend.
    var isTextArea: Bool { isMultiline && !wraps && !isSecure }

    /// The selection's start as a character (Unicode scalar) offset.
    var selectionCharacterOffset: Int? {
        guard let selection else { return nil }
        return Self.characterOffset(ofUTF16: selection.lowerBound, in: text)
    }

    /// The Unicode scalar offset of the UTF-16 offset `offset` in `text`.
    static func characterOffset(ofUTF16 offset: Int, in text: String) -> Int {
        let utf16 = text.utf16
        let index = utf16.index(utf16.startIndex, offsetBy: min(max(0, offset), utf16.count))
        let scalars = text.unicodeScalars
        let scalar = index.samePosition(in: scalars) ?? scalars.index(before: index)
        return scalars.distance(from: scalars.startIndex, to: scalar)
    }

    /// The paragraph (from 0) the selection starts in.
    var selectionLine: Int? {
        guard let selection else { return nil }
        var line = 0, offset = 0
        for unit in text.utf16 {
            guard offset < selection.lowerBound else { break }
            if unit == 0x0A { line += 1 }
            offset += 1
        }
        return line
    }
}
#endif
