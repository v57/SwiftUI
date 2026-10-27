#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// The backend's view for one platform render node. The tree is retained in Swift and painted
/// into the window's drawing area; frames are relative to the parent node (top-left origin).
@MainActor
final class GtkNode {
    weak var node: RenderNode?
    weak var parent: GtkNode?
    var content: RenderContent = .empty
    var frame: CGRect = .zero
    var presentation = RenderPresentation.identity
    var children: [GtkNode] = []

    // Interaction state.
    var isPressed = false
    var isHovered = false

    // Scroll views: the backend owns the offset (reported through `actions.scrolled`).
    var scrollOffset = CGPoint.zero
    var lastScrollRequestID = 0
    var appliedInitialAnchor = false

    /// A native widget shown for this node (text being edited, embedded platform views).
    var nativeWidget: UnsafeMutablePointer<GtkWidget>?
    /// The node's text editor while it is being edited.
    var editor: GtkTextEditor?
    /// A `TextEditor`: its text laid out for the canvas, and how far it is scrolled (the native text view takes the
    /// offset while editing and gives it back).
    var textArea: GtkTextArea?
    var textScroll: CGFloat = 0
    /// The selection the canvas last scrolled to.
    var revealedSelection: Range<Int>?

    init() {}

    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }

    var actions: RenderActions { node?.actions ?? RenderActions() }

    var isEnabled: Bool {
        switch content {
        case .button(let button): return button.isEnabled
        case .toggle(let toggle): return toggle.isEnabled
        case .textField(let field): return field.isEnabled
        case .slider(let slider): return slider.isEnabled
        case .datePicker(let picker): return picker.isEnabled
        default: return true
        }
    }

    var scrollModel: ResolvedScrollView? {
        if case .scrollView(let model) = content { return model }
        return nil
    }

    var effect: DisplayEffect? {
        if case .effect(let effect) = content { return effect }
        return nil
    }

    // MARK: Transforms

    /// Parent → local coordinates: frame origin, presentation (transition) and transform effects.
    var transform: cairo_matrix_t {
        var matrix = cairo_matrix_t()
        cairo_matrix_init_translate(&matrix, Double(frame.minX), Double(frame.minY))
        if !presentation.isIdentity {
            applyTransform(&matrix, offset: presentation.offset, scale: presentation.scale, rotation: presentation.rotationDegrees, anchor: presentation.anchor)
        }
        switch effect {
        case let .transform(offset, scale, rotation, anchor):
            applyTransform(&matrix, offset: offset, scale: scale, rotation: rotation, anchor: anchor)
        case .projection(let m):
            var projection = Self.affineFit(m, size: frame.size)
            var result = cairo_matrix_t()
            cairo_matrix_multiply(&result, &projection, &matrix)
            matrix = result
        default:
            break
        }
        return matrix
    }

    private func applyTransform(_ matrix: inout cairo_matrix_t, offset: CGSize, scale: CGSize, rotation: Double, anchor: UnitPoint) {
        cairo_matrix_translate(&matrix, Double(offset.width), Double(offset.height))
        guard scale != CGSize(width: 1, height: 1) || rotation != 0 else { return }
        let ax = Double(anchor.x * frame.width), ay = Double(anchor.y * frame.height)
        cairo_matrix_translate(&matrix, ax, ay)
        if rotation != 0 { cairo_matrix_rotate(&matrix, rotation * .pi / 180) }
        cairo_matrix_scale(&matrix, Double(max(scale.width, 0.0001)), Double(max(scale.height, 0.0001)))
        cairo_matrix_translate(&matrix, -ax, -ay)
    }

    /// The affine transform closest to a projective one over a `size` box (cairo has no
    /// perspective): the box's corners are projected exactly (with the perspective divide) and an
    /// affine map is least-squares fitted to them. Perspective scale and translation (e.g. from
    /// `rotation3DEffect`'s `anchorZ`) are kept; only the keystone shape is lost.
    static func affineFit(_ m: ProjectionTransform, size: CGSize) -> cairo_matrix_t {
        var result = cairo_matrix_t()
        let affine = m.m13 == 0 && m.m23 == 0 && m.m33 == 1
        let w = max(Double(size.width), 1), h = max(Double(size.height), 1)
        let corners = [(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)]
        var projected: [(Double, Double)] = []
        for (x, y) in corners {
            let d = x * Double(m.m13) + y * Double(m.m23) + Double(m.m33)
            guard d > 1e-6 else { break }
            projected.append(((x * Double(m.m11) + y * Double(m.m21) + Double(m.m31)) / d,
                              (x * Double(m.m12) + y * Double(m.m22) + Double(m.m32)) / d))
        }
        guard !affine, projected.count == 4 else {
            cairo_matrix_init(&result, Double(m.m11), Double(m.m12), Double(m.m21), Double(m.m22), Double(m.m31), Double(m.m32))
            return result
        }
        // Normal equations: (Σ v vᵀ) a = Σ v·target, with v = (x, y, 1).
        var n = [[Double]](repeating: [0, 0, 0], count: 3)
        var bx = [0.0, 0.0, 0.0], by = [0.0, 0.0, 0.0]
        for ((x, y), (px, py)) in zip(corners, projected) {
            let v = [x, y, 1]
            for i in 0..<3 {
                for j in 0..<3 { n[i][j] += v[i] * v[j] }
                bx[i] += v[i] * px
                by[i] += v[i] * py
            }
        }
        func solve(_ b: [Double]) -> [Double] {
            func det(_ a: [[Double]]) -> Double {
                a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                    + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
            }
            let d = det(n)
            return (0..<3).map { column in
                var a = n
                for row in 0..<3 { a[row][column] = b[row] }
                return det(a) / d
            }
        }
        let ax = solve(bx), ay = solve(by)
        // x' = ax0·x + ax1·y + ax2, y' = ay0·x + ay1·y + ay2.
        cairo_matrix_init(&result, ax[0], ay[0], ax[1], ay[1], ax[2], ay[2])
        return result
    }

    /// Offset applied to children (scroll views scroll their content).
    var childOffset: CGPoint {
        guard scrollModel != nil else { return .zero }
        return CGPoint(x: -scrollOffset.x, y: -scrollOffset.y)
    }

    /// The node's rect in window coordinates (translations only), and the visible part of it
    /// after enclosing scroll views clip it.
    func windowRect() -> (rect: CGRect, visible: CGRect) {
        var origin = frame.origin
        origin.x += presentation.offset.width
        origin.y += presentation.offset.height
        if case let .transform(offset, _, _, _) = effect {
            origin.x += offset.width; origin.y += offset.height
        }
        var visible = CGRect(origin: origin, size: frame.size)
        var current = parent
        while let node = current {
            let shift = node.childOffset
            origin.x += shift.x; origin.y += shift.y
            visible = visible.offsetBy(dx: shift.x, dy: shift.y)
            if node.scrollModel?.clipsContent == true || node.isClip {
                visible = visible.intersection(node.bounds)
            }
            let o = node.frame.origin
            let extra = node.presentation.offset
            origin.x += o.x + extra.width; origin.y += o.y + extra.height
            visible = visible.offsetBy(dx: o.x + extra.width, dy: o.y + extra.height)
            current = node.parent
        }
        return (CGRect(origin: origin, size: frame.size), visible)
    }

    private var isClip: Bool {
        if case .clip = effect { return true }
        return false
    }

    // MARK: Drawing

    func draw(_ cr: Cairo, backend: GtkBackend) {
        if case .effect(.maskSource) = content { return } // drawn by its `.mask` parent
        cairo_save(cr)
        var matrix = transform
        cairo_transform(cr, &matrix)
        // Views wholly outside the area being redrawn (scrolled out of sight, outside a damaged region) are skipped.
        if let margin = cullMargin {
            var x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0
            cairo_clip_extents(cr, &x1, &y1, &x2, &y2)
            let clip = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            if !clip.intersects(bounds.insetBy(dx: -margin, dy: -margin)) {
                cairo_restore(cr)
                return
            }
        }
        let opacity = presentation.opacity
        if opacity < 1 { cairo_push_group(cr) }
        drawContent(cr, backend: backend)
        if opacity < 1 {
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, max(0, opacity))
        }
        cairo_restore(cr)
    }

    /// How far a node draws outside its frame, when it is known to draw nothing beyond that (nil: it may, as
    /// containers whose children overflow them and canvases do).
    private var cullMargin: CGFloat? {
        switch content {
        case .text, .image, .color, .toggle, .slider, .textField, .datePicker, .colorWell:
            return children.isEmpty ? 8 : nil
        case .shape(let shape):
            guard children.isEmpty else { return nil }
            var margin = shape.lineWidth + (shape.strokeStyle?.lineWidth ?? 0) + 2
            if let shadow = shape.shadow { margin += shadow.radius * 2 + max(abs(shadow.offset.width), abs(shadow.offset.height)) }
            return margin
        case .effect(.shadow(let shadow)):
            let size = frame.size
            guard children.allSatisfy({ $0.presentation.isIdentity && $0.frame.minX >= 0 && $0.frame.minY >= 0
                && $0.frame.maxX <= size.width + 0.5 && $0.frame.maxY <= size.height + 0.5 && $0.cullMargin != nil }) else { return nil }
            return shadow.radius * 2 + max(abs(shadow.offset.width), abs(shadow.offset.height)) + 8
        default:
            return nil
        }
    }

    private func drawChildren(_ cr: Cairo, backend: GtkBackend, _ nodes: ArraySlice<GtkNode>? = nil) {
        for child in nodes ?? children[...] { child.draw(cr, backend: backend) }
    }

    private func drawContent(_ cr: Cairo, backend: GtkBackend) {
        let size = frame.size
        switch content {
        case .empty:
            drawChildren(cr, backend: backend)
        case .text(let text):
            GtkText.draw(text, in: cr, size: size)
        case .color(let color):
            cairo_rectangle(cr, 0, 0, Double(size.width), Double(size.height))
            color.set(cr)
            cairo_fill(cr)
        case .shape(let shape):
            GtkDrawing.drawShape(shape, in: cr, size: size)
        case .image(let image):
            GtkDrawing.drawImage(image, in: cr, size: size)
        case .button(let button):
            GtkTheme.drawButton(button, in: cr, size: size, pressed: isPressed, hovered: isHovered && button.isEnabled)
            let plain = button.style == .plain || button.style == .borderless || button.style == .link
            let dim = (plain && isPressed ? 0.6 : 1) * (button.isEnabled || !plain ? 1 : 0.5)
            if dim < 1 { cairo_push_group(cr) }
            drawChildren(cr, backend: backend)
            if dim < 1 {
                cairo_pop_group_to_source(cr)
                cairo_paint_with_alpha(cr, dim)
            }
        case .toggle(let toggle):
            GtkTheme.drawToggle(toggle, in: cr, size: size, pressed: isPressed, hovered: isHovered && toggle.isEnabled)
        case .textField(let field):
            GtkTheme.drawEntryFrame(field, in: cr, size: size, focused: editor != nil)
            if editor == nil || editor?.isSettling == true {
                if field.isTextArea, !field.text.isEmpty || field.showsLineNumbers {
                    drawTextArea(field, cr, backend: backend)
                } else {
                    GtkDrawing.drawFieldText(field, in: cr, size: size)
                }
            }
        case .slider(let slider):
            GtkTheme.drawSlider(slider, in: cr, size: size, pressed: isPressed, hovered: isHovered && slider.isEnabled)
        case .scrollView(let model):
            cairo_save(cr)
            if model.clipsContent {
                cairo_rectangle(cr, 0, 0, Double(size.width), Double(size.height))
                cairo_clip(cr)
            }
            cairo_translate(cr, Double(-scrollOffset.x), Double(-scrollOffset.y))
            drawChildren(cr, backend: backend)
            cairo_restore(cr)
            GtkDrawing.drawScrollIndicators(model, offset: scrollOffset, in: cr, size: size, visible: backend.host?.scrollIndicatorsVisible(for: self) ?? false)
        case .effect(let effect):
            drawEffect(effect, cr, backend: backend)
        case .datePicker(let picker):
            GtkDrawing.drawDatePicker(picker, in: cr, size: size, pressed: isPressed, hovered: isHovered)
        case .colorWell(let color):
            GtkTheme.drawBezel(prominent: false, enabled: true, tint: nil, isOn: false, radius: nil, in: cr, size: size, pressed: isPressed, hovered: isHovered)
            roundedRect(cr, CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5), radius: 3)
            color.set(cr)
            cairo_fill(cr)
        case .drawing(let commands):
            GtkDrawing.drawCommands(commands, in: cr, size: size)
        case .platformView:
            break // a native widget positioned over the canvas
        }
    }

    private func drawEffect(_ effect: DisplayEffect, _ cr: Cairo, backend: GtkBackend) {
        let size = frame.size
        switch effect {
        case .opacity(let value):
            guard value > 0 else { return }
            if value >= 1 { return drawChildren(cr, backend: backend) }
            cairo_push_group(cr)
            drawChildren(cr, backend: backend)
            cairo_pop_group_to_source(cr)
            cairo_paint_with_alpha(cr, value)
        case .clip(let path):
            addPath(cr, path)
            cairo_clip(cr)
            drawChildren(cr, backend: backend)
        case .shadow(let shadow):
            GtkShadows.draw(self, shadow: shadow, in: cr, backend: backend) { context in self.drawChildren(context, backend: backend) }
            drawChildren(cr, backend: backend)
        case .mask:
            guard let source = children.last, case .effect(.maskSource) = source.content else { return drawChildren(cr, backend: backend) }
            cairo_push_group(cr)
            drawChildren(cr, backend: backend, children.dropLast())
            let content = cairo_pop_group(cr)
            cairo_push_group(cr)
            var matrix = source.transform
            cairo_transform(cr, &matrix)
            source.drawChildren(cr, backend: backend)
            let mask = cairo_pop_group(cr)
            cairo_set_source(cr, content)
            cairo_mask(cr, mask)
            cairo_pattern_destroy(content)
            cairo_pattern_destroy(mask)
        case .colorFilter(let filter):
            cairo_push_group(cr)
            drawChildren(cr, backend: backend)
            let content = cairo_pop_group(cr)
            GtkDrawing.paintFiltered(content, filter: filter, in: cr, size: size)
            cairo_pattern_destroy(content)
        case .blendMode(let mode):
            cairo_push_group(cr)
            drawChildren(cr, backend: backend)
            cairo_pop_group_to_source(cr)
            cairo_set_operator(cr, GtkDrawing.cairoOperator(mode))
            cairo_paint(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        case let .focusable(wantsFocus, showsFocusRing):
            drawChildren(cr, backend: backend)
            if wantsFocus && showsFocusRing {
                roundedRect(cr, CGRect(origin: .zero, size: size).insetBy(dx: -2, dy: -2), radius: 4)
                GtkTheme.accent.set(cr, opacity: 0.6)
                cairo_set_line_width(cr, 2)
                cairo_stroke(cr)
            }
        case .maskSource, .group, .tapTarget, .transform, .projection, .pointer, .contentShape:
            drawChildren(cr, backend: backend)
        }
    }

    // MARK: Hit testing

    typealias Hit = (node: GtkNode, point: CGPoint)

    /// Parent coordinates → local coordinates (nil if the transform can't be inverted).
    private func localPoint(_ point: CGPoint) -> CGPoint? {
        var inverse = transform
        guard cairo_matrix_invert(&inverse) == CAIRO_STATUS_SUCCESS else { return nil }
        var x = Double(point.x), y = Double(point.y)
        cairo_matrix_transform_point(&inverse, &x, &y)
        return CGPoint(x: x, y: y)
    }

    private var isHidden: Bool {
        if case .effect(.maskSource) = content { return true }
        return presentation.opacity <= 0
    }

    /// The node that receives a click at `point` (parent coordinates), with its ancestors —
    /// AppKit's rules: text (without links), colors, shapes and images are click-through; plain
    /// effect containers only pass hits to their content; buttons, controls and effects that
    /// handle the pointer own their frame; `contentShape` limits the area.
    func hitTest(_ point: CGPoint) -> [Hit]? {
        guard !isHidden, let local = localPoint(point) else { return nil }
        let inside = bounds.contains(local)
        if case .clip(let path) = effect, !GtkDrawing.contains(path, local) { return nil }
        if let inShape = contentShapeContains(local), !inShape { return nil }
        if scrollModel != nil, !inside { return nil }
        let shift = childOffset
        let childPoint = CGPoint(x: local.x - shift.x, y: local.y - shift.y)
        var deeper: [Hit]?
        for child in children.reversed() {
            if let path = child.hitTest(childPoint) { deeper = path; break }
        }
        let me: Hit = (self, local)
        switch content {
        case .empty:
            return [me] + (deeper ?? [])
        case .text(let text):
            guard inside, text.effectiveRuns.contains(where: { $0.link != nil }),
                  GtkText.link(at: local, in: text, size: frame.size) != nil else { return nil }
            return [me]
        case .color, .shape, .image, .drawing, .platformView:
            return nil
        case .button, .toggle, .slider, .textField, .datePicker, .colorWell:
            return inside ? [me] : nil
        case .scrollView:
            return [me] + (deeper ?? [])
        case .effect(let effect):
            if handlesPointer {
                // Controls and other pointer handlers inside keep their clicks.
                if let deeper, let target = deeper.last?.node, target.handlesPointer || target.isControl { return [me] + deeper }
                return inside ? [me] : nil
            }
            if let deeper { return [me] + deeper }
            if case .focusable = effect, inside { return [me] }
            if !actions.dropTypes.isEmpty, inside { return [me] }
            return nil
        }
    }

    private var isControl: Bool {
        switch content {
        case .button, .toggle, .slider, .textField, .datePicker, .colorWell: true
        default: false
        }
    }

    /// `contentShape` of this node, or of the content-shape node wrapping its content (a chain
    /// of single-child effects); nil when there is none.
    private func contentShapeContains(_ local: CGPoint) -> Bool? {
        if case .contentShape(let path) = effect { return GtkDrawing.contains(path, local) }
        guard effect != nil else { return nil }
        var node = self
        var point = local
        while node.children.count == 1, let child = node.children.first, child.effect != nil {
            guard let childLocal = child.localPoint(point) else { return nil }
            if case .contentShape(let path) = child.effect { return GtkDrawing.contains(path, childLocal) }
            node = child
            point = childLocal
        }
        return nil
    }

    /// Every node whose frame contains `point` (parent coordinates), outermost first, following
    /// the topmost child at each level — for hover, cursors and scroll-wheel routing.
    func nodesContaining(_ point: CGPoint) -> [Hit] {
        guard !isHidden, let local = localPoint(point) else { return [] }
        let inside = bounds.contains(local)
        if scrollModel != nil, !inside { return [] }
        if case .clip(let path) = effect, !GtkDrawing.contains(path, local) { return [] }
        let shift = childOffset
        let childPoint = CGPoint(x: local.x - shift.x, y: local.y - shift.y)
        for child in children.reversed() {
            let path = child.nodesContaining(childPoint)
            if !path.isEmpty { return [(self, local)] + path }
        }
        if case .empty = content { return [(self, local)] }
        return inside ? [(self, local)] : []
    }

    /// Converts a window point to this node's local coordinates.
    func convertFromWindow(_ point: CGPoint) -> CGPoint {
        var chain: [GtkNode] = []
        var current: GtkNode? = self
        while let node = current { chain.append(node); current = node.parent }
        var p = point
        for node in chain.reversed() {
            if let parent = node.parent {
                let shift = parent.childOffset
                p.x -= shift.x; p.y -= shift.y
            }
            var inverse = node.transform
            guard cairo_matrix_invert(&inverse) == CAIRO_STATUS_SUCCESS else { continue }
            var x = Double(p.x), y = Double(p.y)
            cairo_matrix_transform_point(&inverse, &x, &y)
            p = CGPoint(x: x, y: y)
        }
        return p
    }

    /// Whether this node handles pointer input itself (the deepest such node gets a click).
    var handlesPointer: Bool {
        switch content {
        case .button, .toggle, .slider, .textField, .datePicker, .colorWell:
            return true
        case .effect(let effect):
            if case .tapTarget = effect { return true }
            let actions = self.actions
            return actions.pointer != nil || actions.pressed != nil || actions.dragItem != nil
        case .text(let text):
            return text.effectiveRuns.contains { $0.link != nil }
        default:
            return false
        }
    }

    var kindName: String {
        switch content {
        case .empty: "root"
        case .text(let text): "Text(\(text.string.prefix(16)))"
        case .color: "Color"
        case .shape: "Shape"
        case .image: "Image"
        case .button: "Button"
        case .toggle: "Toggle"
        case .textField: "TextField"
        case .slider: "Slider"
        case .scrollView: "ScrollView"
        case .effect(let effect): "Effect(\(effect))".prefix(40).description
        case .datePicker: "DatePicker"
        case .colorWell: "ColorWell"
        case .drawing: "Canvas"
        case .platformView: "PlatformView"
        }
    }

    /// The subtree with frames (debugging).
    func dump(indent: Int = 0) -> String {
        let f = frame
        var line = String(repeating: "  ", count: indent) + "\(kindName) (\(Int(f.minX)), \(Int(f.minY)), \(Int(f.width)), \(Int(f.height)))"
        let actions = self.actions
        var flags: [String] = []
        if actions.primary != nil { flags.append("primary") }
        if actions.pointer != nil { flags.append("pointer") }
        if actions.pressed != nil { flags.append("pressed") }
        if actions.hover != nil { flags.append("hover") }
        if !flags.isEmpty { line += " [" + flags.joined(separator: ",") + "]" }
        for child in children { line += "\n" + child.dump(indent: indent + 1) }
        return line
    }

    // MARK: Text editors

    /// A `TextEditor`'s text frame: the gutter's width, and the text's insets in the node (the gutter included).
    func textAreaGeometry(_ field: ResolvedTextField) -> (gutter: CGFloat, insets: EdgeInsets) {
        var insets = field.style == .plain ? EdgeInsets() : GtkTheme.metrics.entryInsets
        var gutter: CGFloat = 0
        if field.showsLineNumbers {
            let lines = field.text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            gutter = GtkLineNumbers.width(font: field.font, lineCount: lines)
            insets.leading += gutter
        }
        return (gutter, insets)
    }

    /// The editor's text laid out for its current width.
    @discardableResult
    func layoutTextArea(_ field: ResolvedTextField) -> GtkTextArea {
        let area = textArea ?? GtkTextArea()
        textArea = area
        let insets = textAreaGeometry(field).insets
        area.update(field, width: max(1, frame.width - insets.leading - insets.trailing))
        return area
    }

    /// The largest scroll offset of a `TextEditor`.
    func maxTextScroll(_ field: ResolvedTextField) -> CGFloat {
        let area = layoutTextArea(field)
        let insets = textAreaGeometry(field).insets
        return max(0, area.height + insets.top + insets.bottom - frame.height)
    }

    private func drawTextArea(_ field: ResolvedTextField, _ cr: Cairo, backend: GtkBackend) {
        let size = frame.size
        let (gutter, insets) = textAreaGeometry(field)
        let area = layoutTextArea(field)
        textScroll = min(max(0, textScroll), max(0, area.height + insets.top + insets.bottom - size.height))
        cairo_save(cr)
        cairo_rectangle(cr, 0, 0, Double(size.width), Double(size.height))
        cairo_clip(cr)
        if field.showsLineNumbers {
            area.drawLineNumbers(
                in: cr, font: field.font, gutterWidth: gutter, top: insets.top, scroll: textScroll, visibleHeight: size.height,
                color: field.color, currentLine: field.selectionLine)
        }
        cairo_rectangle(cr, Double(insets.leading), 0, Double(max(0, size.width - insets.leading)), Double(size.height))
        cairo_clip(cr)
        area.draw(
            in: cr, origin: CGPoint(x: insets.leading, y: insets.top), scroll: textScroll, visibleHeight: size.height,
            color: field.color, opacity: field.isEnabled ? 1 : 0.5)
        if editor != nil, let offset = field.selectionCharacterOffset {
            // The caret, while the text view (with the keyboard) settles under the canvas.
            let caret = area.caretRect(ofCharacter: offset)
            cairo_rectangle(cr, Double(insets.leading + caret.minX), Double(insets.top + caret.minY - textScroll), 1, Double(caret.height))
            field.color.set(cr)
            cairo_fill(cr)
        }
        cairo_restore(cr)
        // The scroll indicator, while scrolling.
        let content = area.height + insets.top + insets.bottom
        if content > size.height + 0.5, backend.host?.scrollIndicatorsVisible(for: self) == true {
            let thickness: CGFloat = 4, inset: CGFloat = 3
            let length = max(24, size.height * size.height / content)
            let y = inset + (size.height - length - inset * 2) * min(max(textScroll / (content - size.height), 0), 1)
            roundedRect(cr, CGRect(x: size.width - thickness - inset, y: y, width: thickness, height: length), radius: thickness / 2)
            GtkTheme.foreground.set(cr, opacity: 0.45)
            cairo_fill(cr)
        }
    }

    var descendants: [GtkNode] { children.flatMap { [$0] + $0.descendants } }
}
#endif
