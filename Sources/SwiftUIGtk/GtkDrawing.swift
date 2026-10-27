#if os(Linux)
import Foundation
import CGtk3
import CoreGraphics
import _SwiftUICore

/// Cairo rendering of render-node content.
@MainActor
enum GtkDrawing {
    // MARK: Shapes

    static func drawShape(_ shape: ResolvedShape, in cr: Cairo, size: CGSize) {
        var sx: CGFloat = 1, sy: CGFloat = 1
        if shape.pathSize.width > 0, shape.pathSize.height > 0 {
            sx = size.width / shape.pathSize.width
            sy = size.height / shape.pathSize.height
        }
        // Like the other backends: a gradient paints the filled (or, with a stroke style, the
        // stroked) path; otherwise fill and stroke colors apply.
        let fills = shape.gradient != nil ? shape.strokeStyle == nil : shape.fill != nil
        let strokes = shape.gradient != nil ? shape.strokeStyle != nil : shape.stroke != nil
        if let shadow = shape.shadow {
            cairo_push_group(cr)
            paintShape(shape, cr, size: size, sx: sx, sy: sy, fills: fills, strokes: strokes)
            let content = cairo_pop_group(cr)
            drawShadow(of: content, shadow: shadow, in: cr, size: size)
            cairo_pattern_destroy(content)
        }
        paintShape(shape, cr, size: size, sx: sx, sy: sy, fills: fills, strokes: strokes)
    }

    private static func paintShape(_ shape: ResolvedShape, _ cr: Cairo, size: CGSize, sx: CGFloat, sy: CGFloat, fills: Bool, strokes: Bool) {
        if fills {
            cairo_new_path(cr)
            addPath(cr, shape.path, scaleX: sx, scaleY: sy)
            if let gradient = shape.gradient {
                setPaint(cr, .gradient(gradient), size: size)
            } else {
                (shape.fill ?? .black).set(cr)
            }
            cairo_fill(cr)
        }
        if strokes {
            cairo_new_path(cr)
            addPath(cr, shape.path, scaleX: sx, scaleY: sy)
            applyStroke(cr, width: shape.lineWidth, style: shape.strokeStyle)
            if let gradient = shape.gradient {
                setPaint(cr, .gradient(gradient), size: size)
            } else {
                (shape.stroke ?? .black).set(cr)
            }
            cairo_stroke(cr)
        }
    }

    static func contains(_ path: Path, _ point: CGPoint) -> Bool {
        let cr = scratch
        cairo_new_path(cr)
        addPath(cr, path)
        return cairo_in_fill(cr, Double(point.x), Double(point.y)) != 0
    }

    /// A 1×1 context for geometry queries.
    private static let scratch: Cairo = {
        let surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1)
        return cairo_create(surface)
    }()

    // MARK: Images

    static func drawImage(_ image: ResolvedImage, in cr: Cairo, size: CGSize) {
        if let redacted = image.redactedColor {
            let side = min(size.width, size.height)
            roundedRect(cr, CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side), radius: side / 6)
            redacted.set(cr, opacity: 0.16)
            cairo_fill(cr)
            return
        }
        let tinted = image.renderingMode == nil || image.renderingMode == .monochrome
        let tint = tinted ? image.tint : (image.paletteColors.first ?? image.tint)
        switch image.source {
        case .system:
            drawSymbol(image, color: tint ?? GtkTheme.foreground, in: cr, size: size)
        case .named(let name):
            guard let pixbuf = GtkImages.load(named: name) else { return }
            GtkImages.draw(pixbuf, in: cr, size: size, tint: tint)
        case .platform(let platform):
            if let bitmap = platform.object as? CGImage { return GtkImages.draw(bitmap, in: cr, size: size, tint: tint) }
            guard let pixbuf = platform.object as? GtkPixbuf else { return }
            GtkImages.draw(pixbuf, in: cr, size: size, tint: tint)
        }
    }

    /// SF Symbols are drawn as Material Symbols glyphs (`SymbolFont`), centered in the frame.
    static func drawSymbol(_ image: ResolvedImage, color: Color.Resolved, in cr: Cairo, size: CGSize) {
        guard GtkText.hasSymbolFont else {
            let side = min(size.width, size.height) * 0.8
            roundedRect(cr, CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side), radius: side / 5)
            color.set(cr, opacity: 0.5)
            cairo_set_line_width(cr, 1.5)
            cairo_stroke(cr)
            return
        }
        let glyph = SymbolFont.glyph(for: image)
        let natural = SymbolFont.glyphSize(image)
        let glyphSize = image.isResizable ? min(size.width, size.height) : max(1, min(natural, min(size.width, size.height)))
        let description = GtkText.symbolDescription(size: glyphSize, weight: image.weight, filled: glyph.filled)
        let layout = pango_cairo_create_layout(cr)!
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, glyph.text, -1)
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_extents(layout, &ink, &logical)
        let scale = CGFloat(PANGO_SCALE)
        let width = CGFloat(logical.width) / scale, height = CGFloat(logical.height) / scale
        cairo_move_to(cr, Double((size.width - width) / 2), Double((size.height - height) / 2))
        color.set(cr)
        pango_cairo_show_layout(cr, layout)
        g_object_unref(UnsafeMutableRawPointer(layout))
    }

    // MARK: Text fields (not being edited)

    static func drawFieldText(_ field: ResolvedTextField, in cr: Cairo, size: CGSize) {
        let insets = field.style == .plain ? EdgeInsets() : GtkTheme.metrics.entryInsets
        let isPlaceholder = field.text.isEmpty
        let string = isPlaceholder ? field.placeholder : (field.isSecure ? String(repeating: "•", count: field.text.count) : field.text)
        guard !string.isEmpty else { return }
        let description = GtkText.fontDescription(field.font)
        let layout = pango_cairo_create_layout(cr)!
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, string, -1)
        if !isPlaceholder, !field.isSecure, !field.foregroundRuns.isEmpty {
            let attributes = GtkText.foregroundAttributes(field.foregroundRuns, in: string)
            pango_layout_set_attributes(layout, attributes)
            pango_attr_list_unref(attributes)
        }
        let width = max(0, size.width - insets.leading - insets.trailing)
        pango_layout_set_width(layout, Int32(width * CGFloat(PANGO_SCALE)))
        let multiline = field.isMultiline || field.wraps
        if multiline {
            pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        } else {
            pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END)
        }
        switch field.alignment {
        case .center: pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)
        case .trailing: pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT)
        default: pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT)
        }
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        let height = CGFloat(logical.height) / CGFloat(PANGO_SCALE)
        let y = multiline ? insets.top : ((size.height - height) / 2).rounded()
        cairo_save(cr)
        cairo_rectangle(cr, Double(insets.leading), 0, Double(width), Double(size.height))
        cairo_clip(cr)
        cairo_move_to(cr, Double(insets.leading), Double(y))
        field.color.set(cr, opacity: isPlaceholder ? 0.45 : (field.isEnabled ? 1 : 0.5))
        pango_cairo_show_layout(cr, layout)
        cairo_restore(cr)
    }

    // MARK: Scroll indicators

    /// Overlay scroll indicators (GTK's overlay scrollbars look), shown while scrolling.
    static func drawScrollIndicators(_ model: ResolvedScrollView, offset: CGPoint, in cr: Cairo, size: CGSize, visible: Bool) {
        guard visible, model.showsIndicators else { return }
        let hidden: Set<ScrollIndicatorVisibility> = [.hidden, .never]
        let document = CGSize(width: model.contentSize.width + model.contentOrigin.x, height: model.contentSize.height + model.contentOrigin.y)
        let color = GtkTheme.foreground
        let thickness: CGFloat = 4, inset: CGFloat = 3
        if model.axes.contains(.vertical), !hidden.contains(model.verticalIndicator), document.height > size.height + 0.5 {
            let length = max(24, size.height * size.height / document.height)
            let travel = size.height - length - inset * 2
            let y = inset + travel * min(max(offset.y / (document.height - size.height), 0), 1)
            roundedRect(cr, CGRect(x: size.width - thickness - inset, y: y, width: thickness, height: length), radius: thickness / 2)
            color.set(cr, opacity: 0.45)
            cairo_fill(cr)
        }
        if model.axes.contains(.horizontal), !hidden.contains(model.horizontalIndicator), document.width > size.width + 0.5 {
            let length = max(24, size.width * size.width / document.width)
            let travel = size.width - length - inset * 2
            let x = inset + travel * min(max(offset.x / (document.width - size.width), 0), 1)
            roundedRect(cr, CGRect(x: x, y: size.height - thickness - inset, width: length, height: thickness), radius: thickness / 2)
            color.set(cr, opacity: 0.45)
            cairo_fill(cr)
        }
    }

    // MARK: Date picker

    static func dateText(_ picker: ResolvedDatePicker) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = picker.components.contains(.date) ? .medium : .none
        formatter.timeStyle = picker.components.contains(.hourAndMinute) ? .short : .none
        return formatter.string(from: picker.date)
    }

    static func drawDatePicker(_ picker: ResolvedDatePicker, in cr: Cairo, size: CGSize, pressed: Bool, hovered: Bool) {
        GtkTheme.drawBezel(prominent: false, enabled: picker.isEnabled, tint: nil, isOn: false, radius: nil, in: cr, size: size, pressed: pressed, hovered: hovered)
        let layout = pango_cairo_create_layout(cr)!
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let description = GtkText.fontDescription(Font.Resolved(size: GtkText.bodySize))
        pango_layout_set_font_description(layout, description)
        pango_font_description_free(description)
        pango_layout_set_text(layout, dateText(picker), -1)
        var logical = PangoRectangle()
        pango_layout_get_extents(layout, nil, &logical)
        let width = CGFloat(logical.width) / CGFloat(PANGO_SCALE), height = CGFloat(logical.height) / CGFloat(PANGO_SCALE)
        cairo_move_to(cr, Double(((size.width - width) / 2).rounded()), Double(((size.height - height) / 2).rounded()))
        GtkTheme.foreground.set(cr, opacity: picker.isEnabled ? 1 : 0.5)
        pango_cairo_show_layout(cr, layout)
    }

    // MARK: Canvas

    static func drawCommands(_ commands: [DrawCommand], in cr: Cairo, size: CGSize) {
        for command in commands {
            switch command {
            case let .fill(path, paint):
                cairo_new_path(cr)
                addPath(cr, path)
                setPaint(cr, paint, size: size)
                cairo_fill(cr)
            case let .stroke(path, paint, style):
                cairo_new_path(cr)
                addPath(cr, path)
                applyStroke(cr, width: style.lineWidth, style: style)
                setPaint(cr, paint, size: size)
                cairo_stroke(cr)
            case let .text(text, point, anchor):
                let measured = GtkText.measure(text, proposal: .unspecified)
                cairo_save(cr)
                cairo_translate(cr, Double(point.x - anchor.x * measured.width), Double(point.y - anchor.y * measured.height))
                GtkText.draw(text, in: cr, size: measured)
                cairo_restore(cr)
            }
        }
    }

    // MARK: Shadows and filters

    /// Draws a blurred, offset shadow of `content` (a group pattern in the current space).
    static func drawShadow(of content: OpaquePointer?, shadow: ResolvedShadow, in cr: Cairo, size: CGSize) {
        let radius = max(0, shadow.radius)
        let margin = Int((radius * 2).rounded(.up)) + 2
        // Rasterize at device scale for crisp shadows on HiDPI displays.
        var sx = 1.0, sy = 1.0
        cairo_user_to_device_distance(cr, &sx, &sy)
        let scale = max(1, min(abs(sx), 3))
        let width = Int((Double(size.width) + Double(margin * 2)) * scale), height = Int((Double(size.height) + Double(margin * 2)) * scale)
        guard width > 0, height > 0, width * height < 16_000_000 else { return }
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height))!
        defer { cairo_surface_destroy(surface) }
        let context = cairo_create(surface)!
        cairo_scale(context, scale, scale)
        cairo_translate(context, Double(margin), Double(margin))
        cairo_set_source(context, content)
        cairo_paint(context)
        cairo_destroy(context)
        cairo_surface_flush(surface)
        if radius > 0 { blurAlpha(surface, radius: Int((Double(radius) * scale / 2).rounded(.up))) }
        cairo_surface_mark_dirty(surface)
        cairo_surface_set_device_scale(surface, scale, scale)
        cairo_save(cr)
        shadow.color.set(cr)
        cairo_mask_surface(cr, surface, Double(shadow.offset.width) - Double(margin), Double(shadow.offset.height) - Double(margin))
        cairo_restore(cr)
    }

    /// Three box-blur passes (≈ gaussian) over the alpha channel of an ARGB32 surface.
    private static func blurAlpha(_ surface: OpaquePointer, radius: Int) {
        guard radius > 0, let data = cairo_image_surface_get_data(surface) else { return }
        let width = Int(cairo_image_surface_get_width(surface)), height = Int(cairo_image_surface_get_height(surface))
        let stride = Int(cairo_image_surface_get_stride(surface))
        var alpha = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = data.advanced(by: y * stride).withMemoryRebound(to: UInt32.self, capacity: width) { $0 }
            for x in 0..<width { alpha[y * width + x] = Float(row[x] >> 24) }
        }
        var temp = alpha
        func pass(_ input: [Float], _ output: inout [Float], horizontal: Bool) {
            let (outer, inner) = horizontal ? (height, width) : (width, height)
            let window = Float(radius * 2 + 1)
            for o in 0..<outer {
                func index(_ i: Int) -> Int { horizontal ? o * width + i : i * width + o }
                var sum: Float = 0
                for i in -radius...radius { sum += input[index(min(max(i, 0), inner - 1))] }
                for i in 0..<inner {
                    output[index(i)] = sum / window
                    sum += input[index(min(i + radius + 1, inner - 1))] - input[index(max(i - radius, 0))]
                }
            }
        }
        for _ in 0..<3 {
            pass(alpha, &temp, horizontal: true)
            pass(temp, &alpha, horizontal: false)
        }
        for y in 0..<height {
            let row = data.advanced(by: y * stride).withMemoryRebound(to: UInt32.self, capacity: width) { $0 }
            for x in 0..<width {
                let a = UInt32(max(0, min(255, alpha[y * width + x].rounded())))
                row[x] = a << 24 // premultiplied black; only the alpha is used as a mask
            }
        }
    }

    /// Paints `content` through a color filter (4×5 matrix on unpremultiplied RGBA).
    static func paintFiltered(_ content: OpaquePointer?, filter: ColorFilter, in cr: Cairo, size: CGSize) {
        var sx = 1.0, sy = 1.0
        cairo_user_to_device_distance(cr, &sx, &sy)
        let scale = max(1, min(abs(sx), 3))
        let width = Int((Double(size.width) * scale).rounded(.up)), height = Int((Double(size.height) * scale).rounded(.up))
        guard width > 0, height > 0, width * height < 16_000_000 else { return }
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height))!
        defer { cairo_surface_destroy(surface) }
        let context = cairo_create(surface)!
        cairo_scale(context, scale, scale)
        cairo_set_source(context, content)
        cairo_paint(context)
        cairo_destroy(context)
        cairo_surface_flush(surface)
        let m = matrix(for: filter)
        if let data = cairo_image_surface_get_data(surface) {
            let stride = Int(cairo_image_surface_get_stride(surface))
            for y in 0..<height {
                let row = data.advanced(by: y * stride).withMemoryRebound(to: UInt32.self, capacity: width) { $0 }
                for x in 0..<width {
                    let pixel = row[x]
                    let a = Float(pixel >> 24)
                    guard a > 0 || m[18] != 1 || m[19] != 0 else { continue }
                    let unpremultiply: Float = a > 0 ? 255 / a : 0
                    let r = Float((pixel >> 16) & 0xFF) * unpremultiply, g = Float((pixel >> 8) & 0xFF) * unpremultiply, b = Float(pixel & 0xFF) * unpremultiply
                    func channel(_ row: Int) -> Float {
                        min(255, max(0, m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b + m[row * 5 + 3] * a + m[row * 5 + 4]))
                    }
                    let na = channel(3), f = na / 255
                    let nr = UInt32(channel(0) * f), ng = UInt32(channel(1) * f), nb = UInt32(channel(2) * f)
                    row[x] = (UInt32(na) << 24) | (nr << 16) | (ng << 8) | nb
                }
            }
        }
        cairo_surface_mark_dirty(surface)
        cairo_surface_set_device_scale(surface, scale, scale)
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_paint(cr)
    }

    /// 4×5 color matrices (row-major, translation in 0…255) for `ColorFilter`s.
    static func matrix(for filter: ColorFilter) -> [Float] {
        func saturation(_ s: Float) -> [Float] {
            let r: Float = 0.213 * (1 - s), g: Float = 0.715 * (1 - s), b: Float = 0.072 * (1 - s)
            return [r + s, g, b, 0, 0, r, g + s, b, 0, 0, r, g, b + s, 0, 0, 0, 0, 0, 1, 0]
        }
        switch filter {
        case .grayscale(let amount):
            return saturation(Float(1 - amount))
        case .saturation(let amount):
            return saturation(Float(amount))
        case .brightness(let amount):
            let b = Float(amount) * 255
            return [1, 0, 0, 0, b, 0, 1, 0, 0, b, 0, 0, 1, 0, b, 0, 0, 0, 1, 0]
        case .contrast(let amount):
            let c = Float(amount), t = (1 - c) * 127.5
            return [c, 0, 0, 0, t, 0, c, 0, 0, t, 0, 0, c, 0, t, 0, 0, 0, 1, 0]
        case .hueRotation(let radians):
            let cosA = Float(cos(radians)), sinA = Float(sin(radians))
            let lr: Float = 0.213, lg: Float = 0.715, lb: Float = 0.072
            return [
                lr + cosA * (1 - lr) + sinA * -lr, lg + cosA * -lg + sinA * -lg, lb + cosA * -lb + sinA * (1 - lb), 0, 0,
                lr + cosA * -lr + sinA * 0.143, lg + cosA * (1 - lg) + sinA * 0.14, lb + cosA * -lb + sinA * -0.283, 0, 0,
                lr + cosA * -lr + sinA * -(1 - lr), lg + cosA * -lg + sinA * lg, lb + cosA * (1 - lb) + sinA * lb, 0, 0,
                0, 0, 0, 1, 0,
            ]
        case .invert:
            return [-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]
        case .multiply(let color):
            return [color.red, 0, 0, 0, 0, 0, color.green, 0, 0, 0, 0, 0, color.blue, 0, 0, 0, 0, 0, color.opacity, 0]
        case .luminanceToAlpha:
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2125, 0.7154, 0.0721, 0, 0]
        }
    }

    static func cairoOperator(_ mode: BlendMode) -> cairo_operator_t {
        switch mode {
        case .normal: CAIRO_OPERATOR_OVER
        case .multiply: CAIRO_OPERATOR_MULTIPLY
        case .screen: CAIRO_OPERATOR_SCREEN
        case .overlay: CAIRO_OPERATOR_OVERLAY
        case .darken: CAIRO_OPERATOR_DARKEN
        case .lighten: CAIRO_OPERATOR_LIGHTEN
        case .colorDodge: CAIRO_OPERATOR_COLOR_DODGE
        case .colorBurn: CAIRO_OPERATOR_COLOR_BURN
        case .softLight: CAIRO_OPERATOR_SOFT_LIGHT
        case .hardLight: CAIRO_OPERATOR_HARD_LIGHT
        case .difference: CAIRO_OPERATOR_DIFFERENCE
        case .exclusion: CAIRO_OPERATOR_EXCLUSION
        case .hue: CAIRO_OPERATOR_HSL_HUE
        case .saturation: CAIRO_OPERATOR_HSL_SATURATION
        case .color: CAIRO_OPERATOR_HSL_COLOR
        case .luminosity: CAIRO_OPERATOR_HSL_LUMINOSITY
        case .sourceAtop: CAIRO_OPERATOR_ATOP
        case .destinationOver: CAIRO_OPERATOR_DEST_OVER
        case .destinationOut: CAIRO_OPERATOR_DEST_OUT
        case .plusDarker: CAIRO_OPERATOR_MULTIPLY
        case .plusLighter: CAIRO_OPERATOR_ADD
        }
    }
}
#endif
