#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// Controls are drawn with the GTK theme's own renderers (`gtk_render_*` on style contexts for
/// the widgets' CSS node paths), so buttons, checks, switches, sliders and entries look like
/// native ones without being widgets. Metrics come from the same CSS nodes.
@MainActor
enum GtkTheme {
    typealias StyleContext = UnsafeMutablePointer<GtkStyleContext>

    private static var contexts: [String: StyleContext] = [:]

    /// A style context for a CSS node path ("button", "checkbutton check", ...) plus classes.
    static func context(_ path: String, classes: String? = nil) -> StyleContext {
        let key = path + "|" + (classes ?? "")
        if let cached = contexts[key] { return cached }
        let names = path.split(separator: " ").map { strdup(String($0)) }
        defer { names.forEach { free($0) } }
        var pointers = names.map { UnsafePointer<CChar>($0) }
        let context = pointers.withUnsafeMutableBufferPointer { buffer in
            sui_style_context(buffer.baseAddress, Int32(buffer.count), classes)!
        }
        contexts[key] = context
        return context
    }

    /// Drops cached contexts (theme change).
    static func reset() {
        for context in contexts.values { g_object_unref(UnsafeMutableRawPointer(context)) }
        contexts.removeAll()
        cachedMetrics = nil
    }

    static func state(enabled: Bool = true, pressed: Bool = false, hovered: Bool = false, checked: Bool = false, focused: Bool = false) -> GtkStateFlags {
        var flags: UInt32 = GTK_STATE_FLAG_NORMAL.rawValue
        if !enabled { flags |= GTK_STATE_FLAG_INSENSITIVE.rawValue }
        if pressed { flags |= GTK_STATE_FLAG_ACTIVE.rawValue }
        if hovered { flags |= GTK_STATE_FLAG_PRELIGHT.rawValue }
        if checked { flags |= GTK_STATE_FLAG_CHECKED.rawValue }
        if focused { flags |= GTK_STATE_FLAG_FOCUSED.rawValue }
        return GtkStateFlags(rawValue: flags)
    }

    static func box(_ context: StyleContext, _ state: GtkStateFlags, _ cr: Cairo, _ rect: CGRect) {
        sui_render_box(context, state, cr, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
    }

    /// Theme colors (the theme's named colors, as GTK widgets use them).
    static func namedColor(_ name: String, fallback: Color.Resolved) -> Color.Resolved {
        var rgba = GdkRGBA()
        guard gtk_style_context_lookup_color(context("window", classes: "background"), name, &rgba) != 0 else { return fallback }
        return Color.Resolved(rgba)
    }

    static var windowBackground: Color.Resolved {
        namedColor("theme_bg_color", fallback: Color.Resolved(sui_style_background(context("window", classes: "background"), GTK_STATE_FLAG_NORMAL)))
    }

    static var foreground: Color.Resolved {
        namedColor("theme_fg_color", fallback: Color.Resolved(sui_style_color(context("window", classes: "background"), GTK_STATE_FLAG_NORMAL)))
    }

    static var accent: Color.Resolved {
        namedColor("theme_selected_bg_color", fallback: Color.Resolved(red: 0.21, green: 0.52, blue: 0.89))
    }

    // MARK: Metrics

    struct Metrics {
        var buttonInsets = EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
        var buttonMinHeight: CGFloat = 34
        var check = CGSize(width: 14, height: 14)
        var radio = CGSize(width: 14, height: 14)
        var switchSize = CGSize(width: 48, height: 26)
        var sliderKnob = CGSize(width: 20, height: 20)
        var troughHeight: CGFloat = 4
        var entryInsets = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        var entryHeight: CGFloat = 34
    }

    private static var cachedMetrics: Metrics?

    static var metrics: Metrics {
        if let cachedMetrics { return cachedMetrics }
        var metrics = Metrics()
        let normal = GTK_STATE_FLAG_NORMAL
        func int(_ context: StyleContext, _ property: String) -> CGFloat { CGFloat(sui_style_int(context, normal, property)) }
        func edges(_ context: StyleContext) -> EdgeInsets {
            var padding = GtkBorder(), border = GtkBorder()
            gtk_style_context_get_padding(context, normal, &padding)
            gtk_style_context_get_border(context, normal, &border)
            return EdgeInsets(top: CGFloat(padding.top + border.top), leading: CGFloat(padding.left + border.left),
                              bottom: CGFloat(padding.bottom + border.bottom), trailing: CGFloat(padding.right + border.right))
        }
        let button = context("button", classes: "text-button")
        metrics.buttonInsets = edges(button)
        metrics.buttonMinHeight = max(int(button, "min-height"), 16) + metrics.buttonInsets.top + metrics.buttonInsets.bottom
        let check = context("checkbutton check")
        let checkSide = max(int(check, "min-width"), 12)
        metrics.check = CGSize(width: checkSide, height: max(int(check, "min-height"), 12))
        let radio = context("radiobutton radio")
        metrics.radio = CGSize(width: max(int(radio, "min-width"), 12), height: max(int(radio, "min-height"), 12))
        let slider = context("switch slider")
        let sliderEdges = edges(slider)
        let knob = CGSize(width: max(int(slider, "min-width"), 16) + sliderEdges.leading + sliderEdges.trailing,
                          height: max(int(slider, "min-height"), 16) + sliderEdges.top + sliderEdges.bottom)
        let switchEdges = edges(context("switch"))
        metrics.switchSize = CGSize(width: knob.width * 2 + switchEdges.leading + switchEdges.trailing,
                                    height: knob.height + switchEdges.top + switchEdges.bottom)
        let scaleSlider = context("scale trough slider")
        let scaleEdges = edges(scaleSlider)
        metrics.sliderKnob = CGSize(width: max(int(scaleSlider, "min-width"), 14) + scaleEdges.leading + scaleEdges.trailing,
                                    height: max(int(scaleSlider, "min-height"), 14) + scaleEdges.top + scaleEdges.bottom)
        let trough = context("scale trough")
        metrics.troughHeight = max(int(trough, "min-height"), 2) + edges(trough).top + edges(trough).bottom
        let entry = context("entry")
        metrics.entryInsets = edges(entry)
        metrics.entryHeight = max(int(entry, "min-height"), 16) + metrics.entryInsets.top + metrics.entryInsets.bottom
        cachedMetrics = metrics
        return metrics
    }

    /// GTK's button heights per control size (regular is the theme's; others scale like Adwaita's
    /// small/large buttons).
    static var buttonSizes: [ControlSize: ControlMetrics.SizeVariant] {
        let m = metrics
        let h = m.buttonMinHeight, inset = m.buttonInsets.leading
        return [
            .mini: .init(height: (h * 0.7).rounded(), horizontalInset: (inset * 0.7).rounded()),
            .small: .init(height: (h * 0.82).rounded(), horizontalInset: (inset * 0.8).rounded()),
            .regular: .init(height: h, horizontalInset: inset),
            .large: .init(height: (h * 1.2).rounded(), horizontalInset: (inset * 1.3).rounded()),
            .extraLarge: .init(height: (h * 1.4).rounded(), horizontalInset: (inset * 1.6).rounded()),
        ]
    }

    static func controlMetrics(_ control: ControlKind) -> ControlMetrics {
        let m = metrics
        switch control {
        case .button(let style):
            switch style {
            case .plain, .borderless, .link:
                return ControlMetrics()
            default:
                let lineHeight = GtkText.lineHeight(Font.Resolved(size: GtkText.bodySize))
                let vertical = max(m.buttonInsets.top, (m.buttonMinHeight - lineHeight) / 2)
                var metrics = ControlMetrics(contentInsets: EdgeInsets(top: vertical, leading: m.buttonInsets.leading, bottom: vertical, trailing: m.buttonInsets.trailing),
                                             minSize: CGSize(width: 0, height: m.buttonMinHeight))
                metrics.sizeTable = buttonSizes
                return metrics
            }
        case .checkbox:
            var metrics = ControlMetrics(minSize: m.check)
            metrics.radioSize = m.radio
            return metrics
        case .switch:
            // Grouped forms keep the theme's switch instead of SwiftUI's mini one.
            var metrics = ControlMetrics(minSize: m.switchSize)
            metrics.compactSize = m.switchSize
            return metrics
        case .textField(let style):
            switch style {
            case .plain:
                return ControlMetrics(idealWidth: 120)
            default:
                return ControlMetrics(contentInsets: m.entryInsets, minSize: CGSize(width: 0, height: m.entryHeight), idealWidth: 120, fixedHeight: m.entryHeight)
            }
        case .slider:
            return ControlMetrics(minSize: CGSize(width: 0, height: max(m.sliderKnob.height, 20) + 4), idealWidth: 0)
        case let .datePicker(date, time, style):
            if style == .graphical { return ControlMetrics(minSize: CGSize(width: 280, height: 260)) }
            return ControlMetrics(minSize: CGSize(width: date && time ? 210 : 120, height: m.entryHeight))
        }
    }

    // MARK: Drawing controls

    static func drawButton(_ button: ResolvedButton, in cr: Cairo, size: CGSize, pressed: Bool, hovered: Bool) {
        switch button.style {
        case .plain, .borderless, .link:
            return
        default:
            break
        }
        var radius: CGFloat?
        switch button.borderShape._kind {
        case .automatic: radius = nil
        case .capsule, .circle: radius = size.height / 2
        case .roundedRectangle(let r): radius = r ?? 6
        }
        drawBezel(prominent: button.style == .borderedProminent, enabled: button.isEnabled, tint: button.tint, isOn: button.isOn,
                  radius: radius, in: cr, size: size, pressed: pressed, hovered: hovered)
    }

    static func drawBezel(prominent: Bool, enabled: Bool, tint: Color.Resolved?, isOn: Bool, radius: CGFloat?,
                          in cr: Cairo, size: CGSize, pressed: Bool, hovered: Bool) {
        let rect = CGRect(origin: .zero, size: size)
        let state = self.state(enabled: enabled, pressed: pressed, hovered: hovered, checked: isOn)
        if let tint {
            // A tinted bezel: the tint (prominent) or a light wash of it, like SwiftUI.
            roundedRect(cr, rect, radius: radius ?? 6)
            var fill = prominent ? tint : Color.Resolved(red: tint.red, green: tint.green, blue: tint.blue, opacity: tint.opacity * 0.18)
            if pressed || isOn { fill = Color.Resolved(red: fill.red * 0.85, green: fill.green * 0.85, blue: fill.blue * 0.85, opacity: fill.opacity) }
            fill.set(cr, opacity: enabled ? 1 : 0.5)
            cairo_fill(cr)
            return
        }
        let context = self.context("button", classes: prominent ? "text-button suggested-action" : "text-button")
        if let radius {
            cairo_save(cr)
            roundedRect(cr, rect, radius: radius)
            cairo_clip(cr)
            box(context, state, cr, rect.insetBy(dx: -2, dy: -2))
            cairo_restore(cr)
        } else {
            box(context, state, cr, rect)
        }
    }

    static func drawToggle(_ toggle: ResolvedToggle, in cr: Cairo, size: CGSize, pressed: Bool, hovered: Bool) {
        let m = metrics
        let state = self.state(enabled: toggle.isEnabled, pressed: pressed, hovered: hovered, checked: toggle.isOn && !toggle.isMixed)
        switch toggle.style {
        case .switch:
            // Core sizes switches itself (SwiftUI's fixed switch size); the theme's switch is
            // drawn into that frame.
            let height = min(size.height, m.switchSize.height)
            let rect = CGRect(x: 0, y: ((size.height - height) / 2).rounded(), width: size.width, height: height)
            box(context("switch"), state, cr, rect)
            let knobWidth = rect.width / 2
            let knob = CGRect(x: toggle.isOn ? rect.maxX - knobWidth : rect.minX, y: rect.minY, width: knobWidth, height: rect.height)
            box(context("switch slider"), state, cr, knob)
        case .radio:
            let rect = CGRect(x: 0, y: ((size.height - m.radio.height) / 2).rounded(), width: m.radio.width, height: m.radio.height)
            sui_render_option(context("radiobutton radio"), state, cr, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
        case .button:
            drawBezel(prominent: false, enabled: toggle.isEnabled, tint: nil, isOn: toggle.isOn, radius: nil, in: cr, size: size, pressed: pressed, hovered: hovered)
        default:
            var flags = state.rawValue
            if toggle.isMixed { flags |= GTK_STATE_FLAG_INCONSISTENT.rawValue }
            let rect = CGRect(x: 0, y: ((size.height - m.check.height) / 2).rounded(), width: m.check.width, height: m.check.height)
            sui_render_check(context("checkbutton check"), GtkStateFlags(rawValue: flags), cr, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
        }
    }

    /// The slider's track rect and knob size in a `size` box.
    static func sliderGeometry(size: CGSize) -> (track: CGRect, knob: CGSize) {
        let m = metrics
        let knob = m.sliderKnob
        let track = CGRect(x: knob.width / 2, y: ((size.height - m.troughHeight) / 2).rounded(), width: max(0, size.width - knob.width), height: m.troughHeight)
        return (track, knob)
    }

    static func drawSlider(_ slider: ResolvedSlider, in cr: Cairo, size: CGSize, pressed: Bool, hovered: Bool) {
        let (track, knob) = sliderGeometry(size: size)
        let state = self.state(enabled: slider.isEnabled, pressed: pressed, hovered: hovered)
        let span = slider.range.upperBound - slider.range.lowerBound
        let fraction = span > 0 ? CGFloat((slider.value - slider.range.lowerBound) / span) : 0
        let x = track.minX + track.width * min(max(fraction, 0), 1)
        let trough = CGRect(x: 0, y: track.minY, width: size.width, height: track.height)
        box(context("scale trough"), state, cr, trough)
        box(context("scale trough highlight"), state, cr, CGRect(x: 0, y: track.minY, width: x, height: track.height))
        if slider.showsThumb {
            let knobRect = CGRect(x: x - knob.width / 2, y: ((size.height - knob.height) / 2).rounded(), width: knob.width, height: knob.height)
            box(context("scale trough slider"), state, cr, knobRect)
        }
    }

    static func drawEntryFrame(_ field: ResolvedTextField, in cr: Cairo, size: CGSize, focused: Bool) {
        guard field.style != .plain else { return }
        let state = self.state(enabled: field.isEnabled, focused: focused)
        box(context("entry"), state, cr, CGRect(origin: .zero, size: size))
    }
}
#endif
