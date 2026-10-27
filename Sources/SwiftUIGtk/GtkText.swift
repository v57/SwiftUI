#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Text with Pango: layout and drawing use the same `PangoLayout` setup, so measured sizes and
/// rendering agree. Sizes are in SwiftUI points = GTK logical pixels (GDK scales for HiDPI).
@MainActor
enum GtkText {
    /// The theme's UI font family ("Ubuntu Sans", "Cantarell", ...).
    private(set) static var systemFamily = "Sans"
    /// Body text size in points (the GTK font size converted to pixels).
    private(set) static var bodySize: CGFloat = 15
    static let symbolFamily = "Material Symbols Outlined"
    private(set) static var hasSymbolFont = false

    private static var context: OpaquePointer!

    static func install() {
        guard context == nil else { return }
        if let name = sui_default_font_name() {
            let description = pango_font_description_from_string(name)
            if let family = pango_font_description_get_family(description) { systemFamily = String(cString: family) }
            let size = pango_font_description_get_size(description)
            if size > 0 {
                let points = CGFloat(size) / CGFloat(PANGO_SCALE)
                bodySize = (pango_font_description_get_size_is_absolute(description) != 0 ? points : points * 96 / 72).rounded()
            }
            pango_font_description_free(description)
            g_free(name)
        }
        loadSymbolFont()
        context = pango_font_map_create_context(pango_cairo_font_map_get_default())
        // Unhinted metrics: layout positions don't snap differently between measuring and drawing.
        let options = cairo_font_options_create()
        if let screen = gdk_screen_get_default(), let screenOptions = gdk_screen_get_font_options(screen) {
            cairo_font_options_merge(options, screenOptions)
        }
        cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF)
        pango_cairo_context_set_font_options(context, options)
        cairo_font_options_destroy(options)
        Font.platformStyleMetrics = { styleMetrics($0) }
        Font.platformControlFont = { size in
            switch size {
            case .mini: .system(size: (bodySize * 0.75).rounded())
            case .small: .system(size: (bodySize * 0.85).rounded())
            default: nil
            }
        }
    }

    /// SwiftUI's macOS type scale, relative to the GTK body size.
    static func styleMetrics(_ style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        let body = bodySize
        func s(_ macOS: CGFloat) -> CGFloat { (body * macOS / 13).rounded() }
        switch style {
        case .largeTitle: return (s(26), .regular)
        case .title: return (s(22), .regular)
        case .title2: return (s(17), .regular)
        case .title3: return (s(15), .regular)
        case .headline: return (body, .bold)
        case .subheadline: return (s(11), .regular)
        case .body: return (body, .regular)
        case .callout: return (s(12), .regular)
        case .footnote: return (s(10.5), .regular)
        case .caption: return (s(10.5), .regular)
        case .caption2: return (s(10), .regular)
        }
    }

    /// The Material Symbols font for `Image(systemName:)`: installed fonts, then
    /// `$SWIFTUI_SYMBOL_FONT`, next to the executable, or the Android assets of a source checkout.
    private static func loadSymbolFont() {
        if sui_has_font_family(symbolFamily) != 0 {
            hasSymbolFont = true
            return
        }
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["SWIFTUI_SYMBOL_FONT"] { candidates.append(path) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("MaterialSymbolsOutlined.ttf").path)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(source.appendingPathComponent("Android/swiftui/src/main/assets/MaterialSymbolsOutlined.ttf").path)
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if sui_add_font_file(path) != 0 {
                sui_reload_font_map()
                hasSymbolFont = sui_has_font_family(symbolFamily) != 0
                if hasSymbolFont { return }
            }
        }
        FileHandle.standardError.write(Data("SwiftUI: Material Symbols font not found; Image(systemName:) shows placeholders (Linux/scripts/fetch-assets)\n".utf8))
    }

    // MARK: Fonts

    static func cssWeight(_ weight: Font.Weight) -> Int32 {
        switch weight.value {
        case ..<(-0.7): 100
        case ..<(-0.5): 200
        case ..<(-0.2): 300
        case ..<0.1: 400
        case ..<0.27: 500
        case ..<0.35: 600
        case ..<0.5: 700
        case ..<0.6: 800
        default: 900
        }
    }

    /// A Pango font description (caller frees).
    static func fontDescription(_ font: Font.Resolved) -> OpaquePointer {
        let description = pango_font_description_new()!
        let family: String
        if let name = font.name {
            family = name
        } else {
            switch font.design {
            case .monospaced: family = "Monospace"
            case .serif: family = "Serif"
            default: family = systemFamily
            }
        }
        pango_font_description_set_family(description, family)
        pango_font_description_set_absolute_size(description, Double(font.size) * Double(PANGO_SCALE))
        pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(cssWeight(font.weight))))
        if font.italic { pango_font_description_set_style(description, PANGO_STYLE_ITALIC) }
        if font.width <= -0.25 {
            pango_font_description_set_stretch(description, PANGO_STRETCH_EXTRA_CONDENSED)
        } else if font.width < 0 {
            pango_font_description_set_stretch(description, PANGO_STRETCH_CONDENSED)
        } else if font.width > 0 {
            pango_font_description_set_stretch(description, PANGO_STRETCH_EXPANDED)
        }
        return description
    }

    static func symbolDescription(size: CGFloat, weight: Font.Weight, filled: Bool) -> OpaquePointer {
        let description = pango_font_description_new()!
        pango_font_description_set_family(description, symbolFamily)
        pango_font_description_set_absolute_size(description, Double(size) * Double(PANGO_SCALE))
        let wght = min(max(cssWeight(weight), 100), 700)
        pango_font_description_set_variations(description, "FILL=\(filled ? 1 : 0),wght=\(wght)")
        return description
    }

    // MARK: Layout

    /// Byte ranges of linked runs (for clicks).
    struct LinkRange {
        var range: Range<Int>
        var url: URL
    }

    /// Pango attributes coloring `string`'s runs (Unicode scalar offsets, as `ResolvedTextField` gives them). The
    /// caller unrefs the list.
    static func foregroundAttributes(_ runs: [ResolvedTextField.ForegroundRun], in string: String) -> OpaquePointer {
        let attributes = pango_attr_list_new()!
        func color16(_ value: Float) -> UInt16 { UInt16(max(0, min(1, value)) * 65535) }
        // UTF-8 offsets of the runs' bounds, in one pass over the string.
        var scalar = 0, byte = 0
        var scalars = string.unicodeScalars.makeIterator()
        func advance(to target: Int) -> Int {
            while scalar < target, let next = scalars.next() {
                byte += UTF8.width(next)
                scalar += 1
            }
            return byte
        }
        for run in runs.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where run.range.lowerBound >= scalar {
            let start = advance(to: run.range.lowerBound), end = advance(to: run.range.upperBound)
            guard end > start else { continue }
            let c = run.color
            for attribute in [
                pango_attr_foreground_new(color16(c.red), color16(c.green), color16(c.blue)),
                pango_attr_foreground_alpha_new(max(1, color16(c.opacity))),
            ] {
                guard let attribute else { continue }
                attribute.pointee.start_index = guint(start)
                attribute.pointee.end_index = guint(end)
                pango_attr_list_insert(attributes, attribute)
            }
        }
        return attributes
    }

    /// A configured layout for `text`, wrapped at `width` (nil: one line per paragraph). The
    /// caller unrefs it.
    static func layout(_ text: ResolvedText, width: CGFloat?, links: UnsafeMutablePointer<[LinkRange]>? = nil) -> OpaquePointer {
        let layout = pango_layout_new(context)!
        var string = ""
        var byteOffset = 0
        let attributes = pango_attr_list_new()!
        func insert(_ attribute: UnsafeMutablePointer<PangoAttribute>?, _ start: Int, _ end: Int) {
            guard let attribute else { return }
            attribute.pointee.start_index = guint(start)
            attribute.pointee.end_index = guint(end)
            pango_attr_list_insert(attributes, attribute)
        }
        func color16(_ value: Float) -> UInt16 { UInt16(max(0, min(1, value)) * 65535) }
        for run in text.effectiveRuns {
            var piece = run.string
            var description: OpaquePointer
            if let image = run.image {
                let glyph = SymbolFont.glyph(for: image)
                piece = hasSymbolFont ? glyph.text : "\u{25A1}"
                description = hasSymbolFont
                    ? symbolDescription(size: SymbolFont.glyphSize(image), weight: image.weight, filled: glyph.filled)
                    : fontDescription(run.font)
            } else {
                description = fontDescription(run.font)
            }
            let start = byteOffset
            byteOffset += piece.utf8.count
            string += piece
            guard byteOffset > start else {
                pango_font_description_free(description)
                continue
            }
            insert(pango_attr_font_desc_new(description), start, byteOffset)
            pango_font_description_free(description)
            let color = run.image?.tint ?? run.color
            insert(pango_attr_foreground_new(color16(color.red), color16(color.green), color16(color.blue)), start, byteOffset)
            insert(pango_attr_foreground_alpha_new(max(1, color16(color.opacity))), start, byteOffset)
            if run.strikethrough {
                insert(pango_attr_strikethrough_new(1), start, byteOffset)
                if let lineColor = run.strikethroughStyle?.color {
                    insert(pango_attr_strikethrough_color_new(color16(lineColor.red), color16(lineColor.green), color16(lineColor.blue)), start, byteOffset)
                }
            }
            if run.underline || run.link != nil {
                insert(pango_attr_underline_new(PANGO_UNDERLINE_SINGLE), start, byteOffset)
                if let lineColor = run.underlineStyle?.color {
                    insert(pango_attr_underline_color_new(color16(lineColor.red), color16(lineColor.green), color16(lineColor.blue)), start, byteOffset)
                }
            }
            if run.tracking != 0 { insert(pango_attr_letter_spacing_new(Int32(run.tracking * CGFloat(PANGO_SCALE))), start, byteOffset) }
            if run.baselineOffset != 0 { insert(pango_attr_rise_new(Int32(run.baselineOffset * CGFloat(PANGO_SCALE))), start, byteOffset) }
            if let background = run.background {
                insert(pango_attr_background_new(color16(background.red), color16(background.green), color16(background.blue)), start, byteOffset)
                insert(pango_attr_background_alpha_new(max(1, color16(background.opacity))), start, byteOffset)
            }
            var features: [String] = []
            if run.font.monospacedDigit { features.append("tnum") }
            switch run.font.caps {
            case .smallCaps: features.append("c2sc"); features.append("smcp")
            case .lowercaseSmallCaps: features.append("smcp")
            case .uppercaseSmallCaps: features.append("c2sc")
            case .none: break
            }
            if !features.isEmpty { insert(pango_attr_font_features_new(features.joined(separator: ",")), start, byteOffset) }
            if let url = run.link { links?.pointee.append(LinkRange(range: start..<byteOffset, url: url)) }
        }
        pango_layout_set_text(layout, string, Int32(string.utf8.count))
        pango_layout_set_attributes(layout, attributes)
        pango_attr_list_unref(attributes)
        if let width, width.isFinite {
            pango_layout_set_width(layout, Int32(max(0, width) * CGFloat(PANGO_SCALE)))
            pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        }
        if let lineLimit = text.lineLimit {
            switch text.truncationMode {
            case .head: pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_START)
            case .middle: pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_MIDDLE)
            default: pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
            }
            pango_layout_set_height(layout, -Int32(max(1, lineLimit)))
        }
        switch text.alignment {
        case .center: pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)
        case .trailing: pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT)
        default: pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT)
        }
        if text.lineSpacing != 0 { pango_layout_set_spacing(layout, Int32(text.lineSpacing * CGFloat(PANGO_SCALE))) }
        return layout
    }

    // MARK: Measurement

    struct Metrics {
        var size: CGSize
        var baseline: CGFloat
        var lineHeight: CGFloat
    }

    private struct CacheKey: Hashable {
        var text: ResolvedText
        var width: CGFloat
    }

    private static var cache: [CacheKey: Metrics] = [:]

    static func metrics(_ text: ResolvedText, width: CGFloat?) -> Metrics {
        var key = text
        // Colors don't change the layout.
        key.color = .black
        key.contentTransition = .interpolate
        let cacheKey = CacheKey(text: key, width: width.flatMap { $0.isFinite ? $0 : nil } ?? -1)
        if let cached = cache[cacheKey] { return cached }
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        let layout = self.layout(text, width: width)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        let scale = CGFloat(PANGO_SCALE)
        let lineCount = max(1, pango_layout_get_line_count(layout))
        let height = CGFloat(logical.height) / scale
        let result = Metrics(size: CGSize(width: CGFloat(logical.width + max(0, logical.x)) / scale, height: height),
                             baseline: CGFloat(pango_layout_get_baseline(layout)) / scale,
                             lineHeight: height / CGFloat(lineCount))
        cache[cacheKey] = result
        return result
    }

    /// Height of one line of text in `font`.
    static func lineHeight(_ font: Font.Resolved) -> CGFloat {
        let layout = pango_layout_new(context)!
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let description = fontDescription(font)
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, "Xg", -1)
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        return (CGFloat(logical.height) / CGFloat(PANGO_SCALE)).rounded(.up)
    }

    /// `minimumScaleFactor`: the factor that makes single-line text fit `width`.
    static func fittingScale(_ text: ResolvedText, width: CGFloat?) -> CGFloat {
        guard text.minimumScaleFactor < 1, let width, width.isFinite, width > 0 else { return 1 }
        var single = text
        single.lineLimit = nil
        let natural = metrics(single, width: nil).size.width
        guard natural > width else { return 1 }
        if text.lineLimit == 1 || natural / width <= 1 / text.minimumScaleFactor {
            return max(text.minimumScaleFactor, width / natural)
        }
        return 1
    }

    static func measure(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        let scale = fittingScale(text, width: proposal.width)
        let fitted = scale < 1 ? text.scaled(by: scale) : text
        let metrics = self.metrics(fitted, width: proposal.width)
        var height = metrics.size.height
        if let minimumLines = text.minimumLines, minimumLines > 1 {
            height = max(height, CGFloat(minimumLines) * metrics.lineHeight)
        }
        var width = metrics.size.width
        if let limit = proposal.width, limit.isFinite { width = min(width, limit) }
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    // MARK: Drawing

    /// Draws text in a `size` box at the current origin.
    static func draw(_ text: ResolvedText, in cr: Cairo, size: CGSize) {
        let scale = fittingScale(text, width: size.width)
        let fitted = scale < 1 ? text.scaled(by: scale) : text
        let layout = self.layout(fitted, width: size.width)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        if text.isRedacted {
            drawPlaceholders(layout, color: text.color, in: cr)
            return
        }
        cairo_move_to(cr, 0, 0)
        if let gradient = text.gradient {
            pango_cairo_layout_path(cr, layout)
            let pattern = gradientPattern(gradient, size: size)
            cairo_set_source(cr, pattern)
            cairo_fill(cr)
            cairo_pattern_destroy(pattern)
        } else {
            text.color.set(cr)
            pango_cairo_show_layout(cr, layout)
        }
    }

    /// `redacted(reason: .placeholder)`: a rounded bar per line.
    private static func drawPlaceholders(_ layout: OpaquePointer, color: Color.Resolved, in cr: Cairo) {
        let iter = pango_layout_get_iter(layout)
        defer { pango_layout_iter_free(iter) }
        repeat {
            var logical = PangoRectangle()
            pango_layout_iter_get_line_extents(iter, nil, &logical)
            let scale = CGFloat(PANGO_SCALE)
            let rect = CGRect(x: CGFloat(logical.x) / scale, y: CGFloat(logical.y) / scale + 2,
                              width: CGFloat(logical.width) / scale, height: max(0, CGFloat(logical.height) / scale - 4))
            roundedRect(cr, rect, radius: 3)
            color.set(cr, opacity: 0.16)
            cairo_fill(cr)
        } while pango_layout_iter_next_line(iter) != 0
    }

    /// The link under a point of text laid out in a `size` box.
    static func link(at point: CGPoint, in text: ResolvedText, size: CGSize) -> URL? {
        var links: [LinkRange] = []
        let layout = self.layout(text, width: size.width, links: &links)
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        guard !links.isEmpty else { return nil }
        var index: Int32 = 0
        var trailing: Int32 = 0
        let inside = pango_layout_xy_to_index(layout, Int32(point.x * CGFloat(PANGO_SCALE)), Int32(point.y * CGFloat(PANGO_SCALE)), &index, &trailing)
        guard inside != 0 else { return nil }
        return links.first { $0.range.contains(Int(index)) }?.url
    }
}
#endif
