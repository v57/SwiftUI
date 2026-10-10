#if os(Android)
import Foundation
import SwiftUI2Core

/// Little-endian byte stream shared with the Kotlin host (`org.swiftui2.Commands` reads it).
/// Render changes of one commit are batched into one buffer and applied with a single JNI call.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 4096) { bytes.reserveCapacity(capacity) }

    var isEmpty: Bool { bytes.isEmpty }
    mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func i32(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func i32(_ value: Int) { i32(Int32(clamping: value)) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func f32(_ value: CGFloat) { f32(Float(value)) }
    mutating func f32(_ value: Double) { f32(Float(value)) }

    mutating func f32(_ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func f64(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }

    /// UTF-8 with an i32 length prefix (-1 for nil).
    mutating func string(_ value: String?) {
        guard let value else { return i32(Int32(-1)) }
        var copy = value
        copy.withUTF8 { utf8 in
            i32(utf8.count)
            bytes.append(contentsOf: utf8)
        }
    }

    /// ARGB, 8 bits per channel.
    mutating func color(_ color: Color.Resolved) { u32(Self.argb(color)) }

    /// A color that may be absent (flag byte + ARGB).
    mutating func optionalColor(_ color: Color.Resolved?) {
        bool(color != nil)
        if let color { self.color(color) }
    }

    static func argb(_ color: Color.Resolved) -> UInt32 {
        func channel(_ value: Float) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
        return channel(color.opacity) << 24 | channel(color.red) << 16 | channel(color.green) << 8 | channel(color.blue)
    }

    func withBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        bytes.withUnsafeBytes(body)
    }
}

/// Render commands (the opcodes `org.swiftui2.HostView.apply` understands).
enum Op: UInt8 {
    case create = 1, destroy, frame, children, content, presentation, accessibility
}

/// Platform view kinds (one Kotlin view class each).
enum ViewKind: UInt8 {
    case container = 0, text, color, shape, image, button, toggle, textField, slider, scrollView, effect,
         datePicker, colorWell, drawing, platformView, maskSource

    init(_ content: RenderContent) {
        switch content {
        case .empty: self = .container
        case .text: self = .text
        case .color: self = .color
        case .shape: self = .shape
        case .image: self = .image
        case .button: self = .button
        case .toggle: self = .toggle
        case .textField: self = .textField
        case .slider: self = .slider
        case .scrollView: self = .scrollView
        case .effect(.maskSource): self = .maskSource
        case .effect: self = .effect
        case .datePicker: self = .datePicker
        case .colorWell: self = .colorWell
        case .drawing: self = .drawing
        case .platformView: self = .platformView
        }
    }
}

// MARK: - Content encoding

extension ByteWriter {
    mutating func point(_ p: CGPoint) { f32(p.x); f32(p.y) }

    mutating func path(_ path: Path) {
        let elements = path.elements
        i32(elements.count)
        for element in elements {
            switch element {
            case .move(let p): u8(0); point(p)
            case .line(let p): u8(1); point(p)
            case let .quadCurve(p, c): u8(2); point(c); point(p)
            case let .curve(p, c1, c2): u8(3); point(c1); point(c2); point(p)
            case .closeSubpath: u8(4)
            }
        }
    }

    mutating func gradient(_ gradient: ResolvedGradient) {
        switch gradient.kind {
        case let .linear(start, end):
            u8(0); f32(start.x); f32(start.y); f32(end.x); f32(end.y)
        case let .radial(center, startRadius, endRadius):
            u8(1); f32(center.x); f32(center.y); f32(startRadius); f32(endRadius)
        case let .angular(center, startAngle, endAngle):
            u8(2); f32(center.x); f32(center.y); f32(startAngle); f32(endAngle)
        case let .elliptical(center, startFraction, endFraction):
            u8(3); f32(center.x); f32(center.y); f32(startFraction); f32(endFraction)
        }
        i32(gradient.stops.count)
        for stop in gradient.stops { color(stop.color); f32(stop.location) }
    }

    mutating func optionalGradient(_ gradient: ResolvedGradient?) {
        bool(gradient != nil)
        if let gradient { self.gradient(gradient) }
    }

    mutating func shadow(_ shadow: ResolvedShadow) {
        color(shadow.color); f32(shadow.radius); f32(shadow.offset.width); f32(shadow.offset.height)
    }

    mutating func strokeStyle(_ style: StrokeStyle?) {
        bool(style != nil)
        guard let style else { return }
        u8(style.lineCap == .round ? 1 : style.lineCap == .square ? 2 : 0)
        u8(style.lineJoin == .round ? 1 : style.lineJoin == .bevel ? 2 : 0)
        f32(style.miterLimit)
        i32(style.dash.count)
        for value in style.dash { f32(value) }
        f32(style.dashPhase)
    }

    /// Font: size, weight (CSS 100…900), design, italic, monospaced digits, family name.
    mutating func font(_ font: Font.Resolved) {
        f32(font.size)
        i32(AndroidText.cssWeight(font.weight))
        u8(font.design == .monospaced ? 1 : font.design == .serif ? 2 : font.design == .rounded ? 3 : 0)
        bool(font.italic)
        bool(font.monospacedDigit)
        string(font.name)
        f32(font.width)
    }

    /// Text runs and paragraph attributes (also the text measurement request).
    mutating func text(_ text: ResolvedText) {
        let runs = text.effectiveRuns
        i32(runs.count)
        for run in runs {
            if let image = run.image {
                // Inline symbols are drawn with the symbol font's glyph.
                let glyph = SymbolFont.glyph(for: image)
                u8(1)
                string(glyph.text)
                font(run.font)
                f32(SymbolFont.glyphSize(image))
                i32(AndroidText.cssWeight(image.weight))
                bool(glyph.filled)
                color(image.tint ?? run.color)
            } else {
                u8(0)
                string(run.string)
                font(run.font)
                color(run.color)
            }
            var flags: UInt8 = 0
            if run.strikethrough { flags |= 1 }
            if run.underline { flags |= 2 }
            if run.link != nil { flags |= 4 }
            u8(flags)
            f32(run.tracking)
            f32(run.baselineOffset)
            optionalColor(run.background)
            string(run.link?.absoluteString)
            optionalGradient(run.gradient)
        }
        i32(text.lineLimit ?? -1)
        u8(text.alignment == .center ? 1 : text.alignment == .trailing ? 2 : 0)
        u8(text.truncationMode == .head ? 0 : text.truncationMode == .middle ? 1 : 2)
        f32(text.lineSpacing)
        f32(text.minimumScaleFactor)
        i32(text.minimumLines ?? 0)
        bool(text.isRedacted)
    }

    mutating func content(_ content: RenderContent, actions: RenderActions) {
        switch content {
        case .empty:
            u8(0)
        case .text(let text):
            self.text(text)
        case .color(let color):
            self.color(color)
        case .shape(let shape):
            path(shape.path)
            f32(shape.pathSize.width); f32(shape.pathSize.height)
            optionalColor(shape.fill)
            optionalColor(shape.stroke)
            f32(shape.lineWidth)
            strokeStyle(shape.strokeStyle)
            optionalGradient(shape.gradient)
            bool(shape.shadow != nil)
            if let shadow = shape.shadow { self.shadow(shadow) }
        case .image(let image):
            self.image(image)
        case .button(let button):
            u8(Self.buttonStyle(button.style))
            bool(button.isEnabled)
            optionalColor(button.tint)
            bool(button.isOn)
            switch button.borderShape._kind {
            case .automatic: u8(0); f32(Float(-1))
            case .capsule: u8(1); f32(Float(-1))
            case .circle: u8(2); f32(Float(-1))
            case .roundedRectangle(let radius): u8(3); f32(radius ?? -1)
            }
            bool(button.repeats)
        case .toggle(let toggle):
            bool(toggle.isOn)
            u8(toggle.style == .switch ? 1 : toggle.style == .radio ? 2 : toggle.style == .button ? 3 : 0)
            bool(toggle.isEnabled)
            bool(toggle.isMixed)
            u8(Self.controlSize(toggle.controlSize))
        case .textField(let field):
            string(field.text)
            string(field.placeholder)
            var flags: UInt8 = 0
            if field.isEnabled { flags |= 1 }
            if field.isSecure { flags |= 2 }
            if field.isMultiline { flags |= 4 }
            if field.wantsFocus { flags |= 8 }
            if field.isAutocorrectionDisabled { flags |= 16 }
            if field.wraps { flags |= 32 }
            u8(flags)
            u8(field.style == .plain ? 1 : field.style == .roundedBorder ? 2 : field.style == .squareBorder ? 3 : 0)
            font(field.font)
            color(field.color)
            u8(field.alignment == .center ? 1 : field.alignment == .trailing ? 2 : 0)
            string(field.contentType)
        case .slider(let slider):
            f64(slider.value)
            f64(slider.range.lowerBound)
            f64(slider.range.upperBound)
            bool(slider.isEnabled)
            bool(slider.showsThumb)
        case .scrollView(let scroll):
            u8((scroll.axes.contains(.horizontal) ? 1 : 0) | (scroll.axes.contains(.vertical) ? 2 : 0))
            f32(scroll.contentSize.width); f32(scroll.contentSize.height)
            f32(scroll.contentOrigin.x); f32(scroll.contentOrigin.y)
            let hidden: Set<ScrollIndicatorVisibility> = [.hidden, .never]
            bool(scroll.showsIndicators && !hidden.contains(scroll.verticalIndicator))
            bool(scroll.showsIndicators && !hidden.contains(scroll.horizontalIndicator))
            bool(scroll.isScrollEnabled)
            bool(scroll.clipsContent)
            i32(scroll.scrollRequestID)
            bool(scroll.requestedOffset != nil)
            point(scroll.requestedOffset ?? .zero)
            bool(scroll.initialAnchor != nil)
            f32(scroll.initialAnchor?.x ?? CGFloat(0)); f32(scroll.initialAnchor?.y ?? CGFloat(0))
            u8(Self.bounce(scroll.verticalBounce)); u8(Self.bounce(scroll.horizontalBounce))
            bool(actions.scrollSnapTarget != nil)
        case .effect(let effect):
            self.effect(effect)
            // What the view must handle itself (touches are only claimed when someone listens).
            var flags: UInt8 = 0
            if actions.primary != nil { flags |= 1 }
            if actions.pointer != nil || actions.dragItem != nil { flags |= 2 }
            if actions.pressed != nil { flags |= 4 }
            if actions.secondaryClick != nil { flags |= 8 }
            u8(flags)
        case .datePicker(let picker):
            f64(picker.date.timeIntervalSince1970)
            bool(picker.components.contains(.date))
            bool(picker.components.contains(.hourAndMinute))
            bool(picker.isEnabled)
            u8(picker.style == .graphical ? 1 : 0)
            bool(picker.range != nil)
            f64(picker.range?.lowerBound.timeIntervalSince1970 ?? 0)
            f64(picker.range?.upperBound.timeIntervalSince1970 ?? 0)
        case .colorWell(let color):
            self.color(color)
        case .drawing(let commands):
            i32(commands.count)
            for command in commands {
                switch command {
                case let .fill(path, paint):
                    u8(0); self.path(path); self.paint(paint)
                case let .stroke(path, paint, style):
                    u8(1); self.path(path); self.paint(paint); f32(style.lineWidth); strokeStyle(style)
                case let .text(text, point, anchor):
                    u8(2); self.text(text); self.point(point); f32(anchor.x); f32(anchor.y)
                }
            }
        case .platformView(let token):
            i32((token.object as? AndroidPlatformView)?.id ?? -1)
        }
    }

    mutating func paint(_ paint: ResolvedPaint) {
        switch paint {
        case .color(let color): u8(0); self.color(color)
        case .gradient(let gradient): u8(1); self.gradient(gradient)
        }
    }

    mutating func image(_ image: ResolvedImage) {
        switch image.source {
        case .system(let name):
            let glyph = SymbolFont.glyph(forSystemName: name)
            u8(0)
            string(glyph.text)
            bool(glyph.filled)
            f32(SymbolFont.glyphSize(image))
            i32(AndroidText.cssWeight(image.weight))
        case .named(let name):
            u8(1)
            string(name)
        case .platform(let platform):
            u8(2)
            i32((platform.object as? AndroidBitmap)?.id ?? -1)
        }
        bool(image.isResizable)
        let tinted = image.renderingMode == nil || image.renderingMode == .monochrome
        optionalColor(tinted ? image.tint : (image.paletteColors.first ?? image.tint))
        optionalColor(image.redactedColor)
    }

    mutating func effect(_ effect: DisplayEffect) {
        switch effect {
        case .opacity(let value): u8(1); f32(value)
        case .clip(let path): u8(2); self.path(path)
        case .tapTarget: u8(3)
        case let .transform(offset, scale, rotation, anchor):
            u8(4); f32(offset.width); f32(offset.height); f32(scale.width); f32(scale.height); f32(rotation); f32(anchor.x); f32(anchor.y)
        case .projection(let m):
            u8(5)
            for value in [m.m11, m.m12, m.m13, m.m21, m.m22, m.m23, m.m31, m.m32, m.m33] { f32(value) }
        case .shadow(let shadow): u8(6); self.shadow(shadow)
        case .mask: u8(7)
        case .maskSource: u8(8)
        case .group: u8(9)
        case let .focusable(wantsFocus, showsFocusRing): u8(10); bool(wantsFocus); bool(showsFocusRing)
        case .pointer: u8(11)
        case .colorFilter(let filter):
            u8(12)
            for value in ColorMatrix.matrix(for: filter) { f32(value) }
        case .blendMode(let mode): u8(13); u8(Self.blendMode(mode))
        case .contentShape(let path): u8(14); self.path(path)
        }
    }

    static func buttonStyle(_ style: ButtonStyleKind) -> UInt8 {
        switch style {
        case .automatic: 0
        case .bordered: 1
        case .borderedProminent: 2
        case .borderless: 3
        case .plain: 4
        case .link: 5
        }
    }

    static func controlSize(_ size: ControlSize) -> UInt8 {
        switch size {
        case .mini: 0
        case .small: 1
        case .regular: 2
        case .large: 3
        case .extraLarge: 4
        }
    }

    static func bounce(_ behavior: ScrollBounceBehavior) -> UInt8 {
        switch behavior {
        case .automatic: 0
        case .always: 1
        case .basedOnSize: 2
        }
    }

    /// `android.graphics.BlendMode` ordinals used by the host (`BlendModes.kt`).
    static func blendMode(_ mode: BlendMode) -> UInt8 {
        switch mode {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        case .darken: 4
        case .lighten: 5
        case .colorDodge: 6
        case .colorBurn: 7
        case .softLight: 8
        case .hardLight: 9
        case .difference: 10
        case .exclusion: 11
        case .hue: 12
        case .saturation: 13
        case .color: 14
        case .luminosity: 15
        case .sourceAtop: 16
        case .destinationOver: 17
        case .destinationOut: 18
        case .plusDarker: 19
        case .plusLighter: 20
        }
    }
}

/// 4×5 color matrices (android.graphics.ColorMatrix layout) for `ColorFilter`s.
enum ColorMatrix {
    static func matrix(for filter: ColorFilter) -> [Float] {
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

    private static func saturation(_ s: Float) -> [Float] {
        let r: Float = 0.213 * (1 - s), g: Float = 0.715 * (1 - s), b: Float = 0.072 * (1 - s)
        return [r + s, g, b, 0, 0, r, g + s, b, 0, 0, r, g, b + s, 0, 0, 0, 0, 0, 1, 0]
    }
}
#endif
