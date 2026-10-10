#if canImport(AppKit)
import AppKit
import SwiftUI2Core

@MainActor
protocol PlatformNodeView: AnyObject {
    var node: RenderNode? { get set }
    func apply(_ content: RenderContent, backend: AppKitBackend)
}

/// Base for all node views: flipped, layer-backed, no autoresizing. Opacity and transforms are
/// composed from the view's own effect and the renderer's transition presentation.
class FlippedView: NSView {
    weak var node: RenderNode?
    override var isFlipped: Bool { true }

    var baseAlpha: CGFloat = 1 { didSet { updateAlpha() } }
    /// The view's own transform effect (`scaleEffect`, `rotationEffect`, `GeometryEffect`, ...).
    var effectGeometry: EffectGeometry = .identity { didSet { if effectGeometry != oldValue { updateTransform() } } }
    private var presentation = RenderPresentation.identity

    enum EffectGeometry: Equatable {
        case identity
        /// Scale and rotation about a unit anchor, then the offset (resolved against the bounds).
        case anchored(offset: CGSize, scale: CGSize, rotationDegrees: Double, anchor: UnitPoint)
        case projection(ProjectionTransform)
    }

    func applyPresentation(_ presentation: RenderPresentation) {
        self.presentation = presentation
        updateAlpha()
        updateTransform()
    }

    private func updateAlpha() {
        alphaValue = baseAlpha * CGFloat(presentation.opacity)
    }

    private static func anchored(offset: CGSize, scale: CGSize, rotationDegrees: Double, anchor: UnitPoint, size: CGSize) -> CGAffineTransform {
        let ax = anchor.x * size.width, ay = anchor.y * size.height
        var t = CGAffineTransform(translationX: offset.width + ax, y: offset.height + ay)
        t = t.rotated(by: CGFloat(rotationDegrees * .pi / 180))
        t = t.scaledBy(x: scale.width, y: scale.height)
        return t.translatedBy(x: -ax, y: -ay)
    }

    /// Composes the effect and presentation transforms for the current bounds.
    private func updateTransform() {
        let size = bounds.size
        var effect = CATransform3DIdentity
        switch effectGeometry {
        case .identity: break
        case let .anchored(offset, scale, rotation, anchor):
            effect = CATransform3DMakeAffineTransform(Self.anchored(offset: offset, scale: scale, rotationDegrees: rotation, anchor: anchor, size: size))
        case let .projection(matrix):
            effect = CATransform3D(matrix)
        }
        var transform = effect
        if !presentation.isIdentity {
            let p = Self.anchored(offset: presentation.offset, scale: presentation.scale, rotationDegrees: presentation.rotationDegrees, anchor: presentation.anchor, size: size)
            transform = CATransform3DConcat(effect, CATransform3DMakeAffineTransform(p))
        }
        appliedTransform = transform
        layer?.transform = transform
    }

    /// AppKit owns a layer-backed view's layer geometry and resets the layer transform when it
    /// syncs the frame (on frame changes and before drawing); these hooks put ours back.
    private var appliedTransform = CATransform3DIdentity

    private func reapplyTransform() {
        guard let layer, !CATransform3DEqualToTransform(layer.transform, appliedTransform) else { return }
        layer.transform = appliedTransform
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = []
    }

    // Anchored transforms depend on the size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if effectGeometry != .identity || !presentation.isIdentity { updateTransform() } else { reapplyTransform() }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reapplyTransform()
    }

    override func layout() {
        super.layout()
        reapplyTransform()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        reapplyTransform()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Click-through follows the hosting view (`allowsWindowActivationEvents`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        var view = superview
        while let current = view {
            if let host = current as? GraphHostingView { return host.acceptsFirstMouseEvents }
            view = current.superview
        }
        return super.acceptsFirstMouse(for: event)
    }

    // MARK: Accessibility

    /// Properties from accessibility modifiers (nil: the view's default accessibility).
    private(set) var accessibilityProperties: AccessibilityProperties?

    /// The view that represents this node to assistive technologies (a wrapped control, if any).
    var accessibilityTarget: NSView { self }

    func applyAccessibility(_ properties: AccessibilityProperties?) {
        accessibilityProperties = properties
        guard let properties else { return }
        let target = accessibilityTarget
        if properties.isHidden {
            target.setAccessibilityElement(false)
            return
        }
        let traits = properties.traits
        let isElement = properties.children != nil || properties.label != nil || properties.value != nil || !traits.isEmpty || !properties.actions.isEmpty
        if isElement, target === self { setAccessibilityElement(true) }
        var label = properties.label
        if label == nil, properties.children == .combine { label = combinedAccessibilityLabel(of: self) }
        if let label { target.setAccessibilityLabel(label) }
        if let value = properties.value { target.setAccessibilityValue(value) }
        if let hint = properties.hint { target.setAccessibilityHelp(hint) }
        if let identifier = properties.identifier { target.setAccessibilityIdentifier(identifier) }
        if !properties.inputLabels.isEmpty { target.setAccessibilityUserInputLabels(properties.inputLabels) }
        if traits.contains(.isSelected) { target.setAccessibilitySelected(true) }
        if properties.headingLevel != nil || traits.contains(.isHeader) { target.setAccessibilityRoleDescription("heading") }
        if target === self {
            let role: NSAccessibility.Role? =
                traits.contains(.isButton) ? .button
                : traits.contains(.isLink) ? .link
                : traits.contains(.isToggle) ? .checkBox
                : traits.contains(.isSearchField) ? .textField
                : traits.contains(.isImage) ? .image
                : traits.contains(.isStaticText) || traits.contains(.isHeader) ? .staticText
                : properties.children != nil ? .group : nil
            if let role { setAccessibilityRole(role) }
        }
        let custom = properties.actions.compactMap { handler -> NSAccessibilityCustomAction? in
            let name: String
            switch handler.kind {
            case .named(let title): name = title
            case .standard(.delete): name = "Delete"
            case .standard(.magicTap): name = "Magic Tap"
            case .scroll(let edge): name = "Scroll \(edge)"
            case .zoom(let direction): name = direction == .zoomIn ? "Zoom In" : "Zoom Out"
            default: return nil
            }
            let perform = handler.perform
            return NSAccessibilityCustomAction(name: name) { MainActor.assumeIsolated { perform() }; return true }
        }
        target.setAccessibilityCustomActions(custom.isEmpty ? nil : custom)
    }

    private func combinedAccessibilityLabel(of view: NSView) -> String? {
        var parts: [String] = []
        func visit(_ view: NSView) {
            for child in view.subviews {
                if let text = child.accessibilityLabel() ?? (child.accessibilityValue() as? String), !text.isEmpty { parts.append(text) } else { visit(child) }
            }
        }
        visit(view)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func performAccessibilityAction(_ kind: AccessibilityActionHandler.Kind) -> Bool {
        guard let handler = accessibilityProperties?.actions.last(where: { $0.kind == kind }) else { return false }
        handler.perform()
        return true
    }

    override func accessibilityPerformPress() -> Bool { performAccessibilityAction(.standard(.default)) || super.accessibilityPerformPress() }
    override func accessibilityPerformIncrement() -> Bool { performAccessibilityAction(.adjust(.increment)) || super.accessibilityPerformIncrement() }
    override func accessibilityPerformDecrement() -> Bool { performAccessibilityAction(.adjust(.decrement)) || super.accessibilityPerformDecrement() }
    override func accessibilityPerformCancel() -> Bool { performAccessibilityAction(.standard(.escape)) || super.accessibilityPerformCancel() }
    override func accessibilityPerformShowMenu() -> Bool { performAccessibilityAction(.standard(.showMenu)) || super.accessibilityPerformShowMenu() }

    override func accessibilityChildren() -> [Any]? {
        if let properties = accessibilityProperties, properties.isHidden || properties.children == .ignore || properties.children == .combine { return [] }
        return super.accessibilityChildren()
    }

    override func accessibilityActivationPoint() -> NSPoint {
        guard let point = accessibilityProperties?.activationPoint, let window else { return super.accessibilityActivationPoint() }
        let local = CGPoint(x: bounds.width * point.x, y: bounds.height * point.y)
        return window.convertPoint(toScreen: convert(local, to: nil))
    }
}

final class TextNodeView: FlippedView, PlatformNodeView {
    private var string = NSAttributedString()
    private var resolved: ResolvedText?
    private var fittedWidth: CGFloat?

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .text(let text) = content else { return }
        resolved = text
        fittedWidth = nil
        string = AppKitText.attributedString(text, placeholders: true)
        // Like SwiftUI, text is a static-text accessibility element (modifiers may override).
        setAccessibilityElement(accessibilityProperties?.isHidden != true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text.string)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // `minimumScaleFactor`: shrink to the frame's width, as measured.
        if let resolved, resolved.minimumScaleFactor < 1, fittedWidth != bounds.width {
            fittedWidth = bounds.width
            string = AppKitText.attributedString(resolved.scaled(by: AppKitText.fittingScale(resolved, width: bounds.width)), placeholders: true)
        }
        string.draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        drawInlineImages()
    }

    /// Draws inline images over their zero-height placeholders, on the line's baseline.
    private func drawInlineImages() {
        var images: [(NSRange, NSTextAttachment)] = []
        string.enumerateAttribute(AppKitText.inlineImageKey, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { images.append((range, attachment)) }
        }
        guard !images.isEmpty else { return }
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        for (range, attachment) in images {
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0, let image = attachment.image else { continue }
            let line = layout.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            guard line.minY < bounds.height else { continue }
            let location = layout.location(forGlyphAt: glyphRange.location)
            // Lines holding only placeholders report no glyph baseline; use the font's.
            let font = string.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            let baseline = line.minY + max(location.y, layout.defaultBaselineOffset(for: font))
            let frame = CGRect(x: line.minX + location.x, y: baseline - attachment.bounds.maxY,
                               width: attachment.bounds.width, height: attachment.bounds.height)
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private var hasLinks: Bool {
        var found = false
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Text is click-through unless it contains links.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hasLinks, let superview else { return nil }
        return link(at: convert(point, from: superview)) != nil ? self : nil
    }

    private func link(at point: NSPoint) -> URL? {
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < string.length,
              layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: container).contains(point)
        else { return nil }
        return string.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    override func mouseUp(with event: NSEvent) {
        guard let url = link(at: convert(event.locationInWindow, from: nil)) else { return super.mouseUp(with: event) }
        if let open = node?.actions.openURL { open(url) } else { NSWorkspace.shared.open(url) }
    }

    override func mouseDown(with event: NSEvent) {
        if link(at: convert(event.locationInWindow, from: nil)) == nil { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        guard hasLinks else { return }
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard value != nil else { return }
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

final class ColorNodeView: FlippedView, PlatformNodeView {
    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .color(let color) = content else { return }
        layer?.backgroundColor = NSColor(color).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ShapeNodeView: FlippedView, PlatformNodeView {
    private let shapeLayer = CAShapeLayer()
    private var gradientLayer: CAGradientLayer?
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var shape: ResolvedShape?

    /// The shape's path scaled from the size it was built for to the current bounds.
    private func scaledPath(_ shape: ResolvedShape) -> CGPath {
        let path = shape.path.cgPath
        guard shape.pathSize.width > 0, shape.pathSize.height > 0, bounds.size != shape.pathSize else { return path }
        var transform = CGAffineTransform(scaleX: bounds.width / shape.pathSize.width, y: bounds.height / shape.pathSize.height)
        return path.copy(using: &transform) ?? path
    }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .shape(let shape) = content else { return }
        self.shape = shape
        let path = scaledPath(shape)
        shapeLayer.path = path
        shapeLayer.lineWidth = shape.lineWidth
        if let style = shape.strokeStyle {
            shapeLayer.lineCap = style.lineCap == .round ? .round : style.lineCap == .square ? .square : .butt
            shapeLayer.lineJoin = style.lineJoin == .round ? .round : style.lineJoin == .bevel ? .bevel : .miter
            shapeLayer.lineDashPattern = style.dash.isEmpty ? nil : style.dash.map { NSNumber(value: Double($0)) }
            shapeLayer.lineDashPhase = style.dashPhase
            shapeLayer.miterLimit = style.miterLimit
        }
        if let gradient = shape.gradient {
            let gradientLayer = self.gradientLayer ?? CAGradientLayer()
            if self.gradientLayer == nil {
                layer?.addSublayer(gradientLayer)
                self.gradientLayer = gradientLayer
            }
            gradientLayer.colors = gradient.stops.map { NSColor($0.color).cgColor }
            gradientLayer.locations = gradient.stops.map { NSNumber(value: Double($0.location)) }
            switch gradient.kind {
            case let .linear(start, end):
                gradientLayer.type = .axial
                gradientLayer.startPoint = CGPoint(x: start.x, y: start.y)
                gradientLayer.endPoint = CGPoint(x: end.x, y: end.y)
            case let .radial(center, _, endRadius):
                gradientLayer.type = .radial
                gradientLayer.startPoint = CGPoint(x: center.x, y: center.y)
                let size = bounds.size
                gradientLayer.endPoint = CGPoint(x: center.x + endRadius / max(size.width, 1), y: center.y + endRadius / max(size.height, 1))
            case let .elliptical(center, _, endFraction):
                gradientLayer.type = .radial
                gradientLayer.startPoint = CGPoint(x: center.x, y: center.y)
                gradientLayer.endPoint = CGPoint(x: center.x + endFraction, y: center.y + endFraction)
            case let .angular(center, _, _):
                gradientLayer.type = .conic
                gradientLayer.startPoint = CGPoint(x: center.x, y: center.y)
                gradientLayer.endPoint = CGPoint(x: center.x, y: 0)
            }
            maskLayer.path = path
            maskLayer.fillColor = shape.strokeStyle == nil ? NSColor.black.cgColor : nil
            maskLayer.strokeColor = shape.strokeStyle == nil ? nil : NSColor.black.cgColor
            maskLayer.lineWidth = shape.lineWidth
            maskLayer.lineDashPattern = shapeLayer.lineDashPattern
            maskLayer.lineCap = shapeLayer.lineCap
            gradientLayer.mask = maskLayer
            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = nil
            gradientLayer.frame = bounds
            maskLayer.frame = bounds
        } else {
            gradientLayer?.removeFromSuperlayer()
            gradientLayer = nil
            shapeLayer.fillColor = shape.fill.map { NSColor($0).cgColor }
            shapeLayer.strokeColor = shape.stroke.map { NSColor($0).cgColor }
        }
    }

    override func layout() {
        super.layout()
        shapeLayer.frame = bounds
        gradientLayer?.frame = bounds
        maskLayer.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        gradientLayer?.frame = bounds
        maskLayer.frame = bounds
        if let shape {
            let path = scaledPath(shape)
            shapeLayer.path = path
            if gradientLayer != nil { maskLayer.path = path }
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ImageNodeView: FlippedView, PlatformNodeView {
    private let imageView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .image(let image) = content else { return }
        imageView.image = AppKitImages.image(image)
        imageView.imageScaling = image.isResizable ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        imageView.contentTintColor = image.tint.map { NSColor($0) }
        imageView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Container for button labels; draws the bezel and handles clicks.
final class ButtonNodeView: FlippedView, PlatformNodeView {
    private var info: ResolvedButton?
    private var isPressed = false { didSet { needsDisplay = true } }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .button(let button) = content else { return }
        info = button
        baseAlpha = button.isEnabled ? 1 : 0.5
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let info else { return }
        switch info.style {
        case .automatic, .bordered:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isPressed ? NSColor.controlColor.blended(withFraction: 0.15, of: .black)! : NSColor.controlColor).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
        case .borderedProminent:
            let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            let tint = info.tint.map { NSColor($0) } ?? .controlAccentColor
            (isPressed ? tint.blended(withFraction: 0.2, of: .black)! : tint).setFill()
            path.fill()
        case .plain, .borderless, .link:
            break
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let info, info.isEnabled else { return }
        isPressed = true
        if info.style == .plain || info.style == .borderless { baseAlpha = 0.6 }
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        let isEnabled = info?.isEnabled ?? true
        baseAlpha = isEnabled ? 1 : 0.5
        if inside, isEnabled { node?.actions.primary?() }
    }
}

final class ToggleNodeView: FlippedView, PlatformNodeView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let toggleSwitch = NSSwitch()
    private var style: ToggleStyleKind = .automatic

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.target = self
        checkbox.action = #selector(changed(_:))
        toggleSwitch.target = self
        toggleSwitch.action = #selector(changed(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .toggle(let toggle) = content else { return }
        let control: NSControl = toggle.style == .switch ? toggleSwitch : checkbox
        if control.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            addSubview(control)
        }
        style = toggle.style
        checkbox.state = toggle.isOn ? .on : .off
        toggleSwitch.state = toggle.isOn ? .on : .off
        control.isEnabled = toggle.isEnabled
        control.frame = bounds
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    @objc private func changed(_ sender: NSControl) {
        let isOn = (sender as? NSButton)?.state == .on || (sender as? NSSwitch)?.state == .on
        node?.actions.setBool?(isOn)
    }
}

final class TextFieldNodeView: FlippedView, PlatformNodeView, NSTextFieldDelegate, NSTextViewDelegate {
    private var showsFindBar = false
    private var field: NSTextField?
    private var scrollView: NSScrollView?
    private var textView: NSTextView?
    private var wantsFocus = false

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .textField(let model) = content else { return }
        if model.isMultiline {
            if textView == nil {
                let scroll = NSTextView.scrollableTextView()
                scroll.autoresizingMask = [.width, .height]
                scroll.borderType = .bezelBorder
                let text = scroll.documentView as! NSTextView
                text.delegate = self
                text.isRichText = false
                addSubview(scroll)
                scrollView = scroll
                textView = text
            }
            if textView!.string != model.text { textView!.string = model.text }
            textView!.isAutomaticSpellingCorrectionEnabled = !model.isAutocorrectionDisabled
            textView!.isAutomaticTextReplacementEnabled = !model.isAutocorrectionDisabled
            textView!.usesFontPanel = model.showsFormattingControls
            textView!.usesRuler = model.showsFormattingControls
            if #available(macOS 15.0, *) {
                switch model.writingTools._kind {
                case .disabled: textView!.writingToolsBehavior = .none
                case .limited: textView!.writingToolsBehavior = .limited
                case .complete: textView!.writingToolsBehavior = .complete
                case .automatic: textView!.writingToolsBehavior = .default
                }
            }
            textView!.usesFindBar = model.isFindEnabled
            textView!.isIncrementalSearchingEnabled = model.isFindEnabled
            if model.showsFindNavigator != showsFindBar {
                showsFindBar = model.showsFindNavigator
                let action: NSTextFinder.Action = showsFindBar ? .showFindInterface : .hideFindInterface
                let item = NSMenuItem()
                item.tag = action.rawValue
                textView!.performTextFinderAction(item)
            }
            // .textEditorStyle(.plain): no bezel or background.
            scrollView!.borderType = model.style == .plain ? .noBorder : .bezelBorder
            textView!.drawsBackground = model.style != .plain
            scrollView!.drawsBackground = model.style != .plain
            textView!.font = AppKitText.font(model.font)
            textView!.isEditable = model.isEnabled
            scrollView!.frame = bounds
        } else {
            let needsSecure = model.isSecure
            if field == nil || (field is NSSecureTextField) != needsSecure {
                field?.removeFromSuperview()
                let created: NSTextField = needsSecure ? NSSecureTextField() : NSTextField()
                created.delegate = self
                created.autoresizingMask = [.width, .height]
                addSubview(created)
                field = created
            }
            let field = self.field!
            if field.stringValue != model.text { field.stringValue = model.text }
            isAutocorrectionDisabled = model.isAutocorrectionDisabled
            field.contentType = model.contentType.map { NSTextContentType(rawValue: $0) }
            field.isAutomaticTextCompletionEnabled = !model.isAutocorrectionDisabled
            field.placeholderString = model.placeholder
            field.isEnabled = model.isEnabled
            field.font = AppKitText.font(model.font)
            if (field.cell?.wraps ?? false) != model.wraps {
                field.cell?.wraps = model.wraps
                field.cell?.isScrollable = !model.wraps
                field.lineBreakMode = model.wraps ? .byWordWrapping : .byClipping
            }
            switch model.style {
            case .plain:
                field.isBordered = false
                field.drawsBackground = false
                field.focusRingType = .none
            case .squareBorder:
                field.isBordered = true
                field.isBezeled = true
                field.bezelStyle = .squareBezel
            default:
                field.isBordered = true
                field.isBezeled = true
                field.bezelStyle = .roundedBezel
            }
            field.frame = bounds
        }
        if model.wantsFocus != wantsFocus {
            wantsFocus = model.wantsFocus
            if wantsFocus {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let target = (self.textView as NSView?) ?? self.field else { return }
                    self.window?.makeFirstResponder(target)
                }
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field { node?.actions.setText?(field.stringValue) }
    }

    private var isAutocorrectionDisabled = false

    func controlTextDidBeginEditing(_ obj: Notification) {
        // The shared field editor takes this field's autocorrection setting.
        if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            editor.isAutomaticSpellingCorrectionEnabled = !isAutocorrectionDisabled
            editor.isAutomaticTextReplacementEnabled = !isAutocorrectionDisabled
        }
        node?.actions.focusChanged?(true)
    }
    func controlTextDidEndEditing(_ obj: Notification) { node?.actions.focusChanged?(false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            node?.actions.submit?()
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        if let textView { node?.actions.setText?(textView.string) }
    }
}

final class DatePickerNodeView: FlippedView, PlatformNodeView {
    private let picker = NSDatePicker()

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.datePickerStyle = .textFieldAndStepper
        picker.target = self
        picker.action = #selector(changed)
        picker.autoresizingMask = [.width, .height]
        addSubview(picker)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .datePicker(let model) = content else { return }
        picker.datePickerStyle = Self.nativeStyle(model.style)
        picker.minDate = model.range?.lowerBound
        picker.maxDate = model.range?.upperBound
        var elements: NSDatePicker.ElementFlags = []
        if model.components.contains(.date) { elements.insert(.yearMonthDay) }
        if model.components.contains(.hourAndMinute) { elements.insert(.hourMinute) }
        picker.datePickerElements = elements
        if picker.dateValue != model.date { picker.dateValue = model.date }
        picker.isEnabled = model.isEnabled
        picker.frame = bounds
    }

    @objc private func changed() { node?.actions.setDate?(picker.dateValue) }

    static func nativeStyle(_ style: DatePickerStyleKind) -> NSDatePicker.Style {
        switch style {
        case .graphical: return .clockAndCalendar
        case .field: return .textField
        case .automatic, .compact, .stepperField: return .textFieldAndStepper
        }
    }
}

final class ColorWellNodeView: FlippedView, PlatformNodeView {
    private let well = NSColorWell(style: .minimal)

    override init(frame: NSRect) {
        super.init(frame: frame)
        well.target = self
        well.action = #selector(changed)
        well.autoresizingMask = [.width, .height]
        layer?.masksToBounds = true
        addSubview(well)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .colorWell(let color) = content else { return }
        well.color = NSColor(color)
        well.frame = bounds
    }

    @objc private func changed() {
        guard let srgb = well.color.usingColorSpace(.sRGB) else { return }
        node?.actions.setColor?(Color.Resolved(red: Float(srgb.redComponent), green: Float(srgb.greenComponent), blue: Float(srgb.blueComponent), opacity: Float(srgb.alphaComponent)))
    }
}

final class SliderNodeView: FlippedView, PlatformNodeView {
    private let slider = NSSlider()

    override init(frame: NSRect) {
        super.init(frame: frame)
        slider.target = self
        slider.action = #selector(changed)
        slider.autoresizingMask = [.width, .height]
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .slider(let model) = content else { return }
        slider.minValue = model.range.lowerBound
        slider.maxValue = model.range.upperBound
        slider.doubleValue = model.value
        slider.isEnabled = model.isEnabled
        slider.frame = bounds
    }

    @objc private func changed() {
        node?.actions.setDouble?(slider.doubleValue)
    }
}

final class ScrollNodeView: FlippedView, PlatformNodeView {
    private let scrollView = NSScrollView()
    let documentContainer = FlippedView()
    private var lastRequestID = 0
    private var reportedOffset = CGPoint.zero
    private var appliedInitialAnchor = false
    private var lastFlashCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = documentContainer
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    @objc private func boundsChanged() {
        let offset = scrollView.contentView.bounds.origin
        guard offset != reportedOffset else { return }
        reportedOffset = offset
        node?.actions.scrolled?(offset)
    }

    @objc private func liveScrollStarted() {
        node?.actions.scrollPhase?(.interacting)
    }

    @objc private func liveScrollEnded() {
        let offset = scrollView.contentView.bounds.origin
        guard let target = node?.actions.scrollSnapTarget?(offset), target != offset else {
            node?.actions.scrollPhase?(.idle)
            return
        }
        // Settle on the snap target (paging / view-aligned), like SwiftUI's target behaviors.
        node?.actions.scrollPhase?(.animating)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                self.node?.actions.scrollPhase?(.idle)
            }
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func elasticity(_ behavior: ScrollBounceBehavior, contentLength: CGFloat, viewport: CGFloat) -> NSScrollView.Elasticity {
        switch behavior {
        case .automatic: return .automatic
        case .always: return .allowed
        case .basedOnSize: return contentLength > viewport + 0.5 ? .allowed : .none
        }
    }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .scrollView(let model) = content else { return }
        let hidden: Set<ScrollIndicatorVisibility> = [.hidden, .never]
        scrollView.hasVerticalScroller = model.axes.contains(.vertical) && model.showsIndicators && !hidden.contains(model.verticalIndicator)
        scrollView.hasHorizontalScroller = model.axes.contains(.horizontal) && model.showsIndicators && !hidden.contains(model.horizontalIndicator)
        scrollView.autohidesScrollers = model.verticalIndicator != .visible && model.horizontalIndicator != .visible
        scrollView.frame = bounds
        let documentSize = CGSize(width: max(model.contentSize.width + model.contentOrigin.x, model.axes.contains(.horizontal) ? 0 : bounds.width),
                                  height: max(model.contentSize.height + model.contentOrigin.y, model.axes.contains(.vertical) ? 0 : bounds.height))
        documentContainer.frame = CGRect(origin: .zero, size: documentSize)
        scrollView.verticalScrollElasticity = model.axes.contains(.vertical)
            ? Self.elasticity(model.verticalBounce, contentLength: documentSize.height, viewport: bounds.height) : .none
        scrollView.horizontalScrollElasticity = model.axes.contains(.horizontal)
            ? Self.elasticity(model.horizontalBounce, contentLength: documentSize.width, viewport: bounds.width) : .none
        clipsToBounds = model.clipsContent
        scrollView.clipsToBounds = model.clipsContent
        scrollView.contentView.clipsToBounds = model.clipsContent
        if model.scrollRequestID != lastRequestID, let target = model.requestedOffset {
            lastRequestID = model.scrollRequestID
            reportedOffset = target
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if !appliedInitialAnchor, let anchor = model.initialAnchor, bounds.width > 0, bounds.height > 0,
                  documentSize.width > 0, documentSize.height > 0 {
            // defaultScrollAnchor: start at the anchor once the content has a size.
            appliedInitialAnchor = true
            let target = CGPoint(x: max(0, (documentSize.width - bounds.width) * anchor.x),
                                 y: max(0, (documentSize.height - bounds.height) * anchor.y))
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if model.flashCount != lastFlashCount {
            lastFlashCount = model.flashCount
            if model.flashCount > 0 { scrollView.flashScrollers() }
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }
}

/// The content of `.mask { ... }`: never shown itself, drawn into its container's layer mask.
final class MaskSourceNodeView: FlippedView, PlatformNodeView {
    func apply(_ content: RenderContent, backend: AppKitBackend) {}
}

final class EffectNodeView: FlippedView, PlatformNodeView {
    private var isTapTarget = false

    // MARK: Focus (`focusable`)

    private var isFocusable = false
    override var acceptsFirstResponder: Bool { isFocusable }
    override var canBecomeKeyView: Bool { isFocusable }

    override func becomeFirstResponder() -> Bool {
        guard isFocusable else { return false }
        node?.actions.focusChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isFocusable { node?.actions.focusChanged?(false) }
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Pointer (`pointerStyle`, `pointerVisibility`)

    private var pointerStyle: PointerStyle?
    private var hidesPointer = false

    override func resetCursorRects() {
        super.resetCursorRects()
        if let pointerStyle { addCursorRect(bounds, cursor: Self.cursor(pointerStyle)) }
    }

    static func cursor(_ style: PointerStyle) -> NSCursor {
        switch style {
        case .default: return .arrow
        case .link: return .pointingHand
        case .grabIdle: return .openHand
        case .grabActive: return .closedHand
        case .horizontalText: return .iBeam
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .rectSelection: return .crosshair
        case .zoomIn: if #available(macOS 15.0, *) { return .zoomIn } else { return .arrow }
        case .zoomOut: if #available(macOS 15.0, *) { return .zoomOut } else { return .arrow }
        case .columnResize: return .resizeLeftRight
        case .rowResize: return .resizeUpDown
        case .frameResize(let position, _):
            switch position {
            case .leading, .trailing: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }
    private let maskLayer = CAShapeLayer()
    private var isMaskContainer = false
    var maskSource: MaskSourceNodeView?

    /// Renders the mask source (offscreen) and uses its alpha as this view's layer mask.
    func refreshMask() {
        guard isMaskContainer else { return }
        guard let source = maskSource, source.bounds.width >= 1, source.bounds.height >= 1 else {
            layer?.mask = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = source.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        source.cacheDisplay(in: source.bounds, to: rep)
        let mask = CALayer()
        mask.frame = source.frame
        mask.contents = rep.cgImage
        mask.contentsGravity = .resize
        layer?.mask = mask
    }

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        baseAlpha = 1
        layer?.mask = nil
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0
        var geometry = EffectGeometry.identity
        defer { effectGeometry = geometry }
        isTapTarget = false
        isMaskContainer = false
        isFocusable = false
        pointerStyle = nil
        hidesPointer = false
        toolTip = node?.actions.toolTip
        defer {
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
        updateDropRegistration()
        guard case .effect(let effect) = content else { return }
        switch effect {
        case .shadow(let shadow):
            layer?.shadowColor = NSColor(shadow.color).cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = shadow.radius
            layer?.shadowOffset = CGSize(width: shadow.offset.width, height: -shadow.offset.height)
        case .opacity(let value):
            baseAlpha = CGFloat(value)
        case .clip(let path):
            maskLayer.path = path.cgPath
            layer?.mask = maskLayer
        case .tapTarget:
            isTapTarget = true
        case .mask:
            isMaskContainer = true
        case .maskSource, .group:
            break
        case let .focusable(wantsFocus, showsFocusRing):
            isFocusable = true
            focusRingType = showsFocusRing ? .exterior : .none
            if wantsFocus, window?.firstResponder !== self {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    window.makeFirstResponder(self)
                }
            } else if !wantsFocus, window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        case let .pointer(style, hidden):
            pointerStyle = style
            hidesPointer = hidden
        case let .projection(matrix):
            geometry = .projection(matrix)
        case let .transform(offset, scale, rotation, anchor):
            geometry = .anchored(offset: offset, scale: scale, rotationDegrees: rotation, anchor: anchor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if handlesPointer, hit === self || hit == nil || !(hit is NSControl) && !(hit is ButtonNodeView) && !((hit as? EffectNodeView)?.handlesPointer ?? false) {
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
        // Drop destinations own their whole area (drag destinations are found by hit testing).
        return hit === self ? (registeredDropTypes.isEmpty && !isFocusable ? nil : self) : hit
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard node?.actions.hover != nil || hidesPointer else { return }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if node?.actions.hoverLocation != nil { options.insert(.mouseMoved) }
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private var pointerHidden = false

    override func mouseEntered(with event: NSEvent) {
        if hidesPointer, !pointerHidden { NSCursor.hide(); pointerHidden = true }
        node?.actions.hover?(true)
        node?.actions.hoverLocation?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let hoverLocation = node?.actions.hoverLocation else { return super.mouseMoved(with: event) }
        hoverLocation(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if pointerHidden { NSCursor.unhide(); pointerHidden = false }
        node?.actions.hover?(false)
        node?.actions.hoverLocation?(nil)
    }

    private var handlesPointer: Bool { isTapTarget || node?.actions.pointer != nil || node?.actions.dragItem != nil }

    // MARK: Drop destination

    private var registeredDropTypes: [String] = []

    private func updateDropRegistration() {
        let types = node?.actions.drop == nil ? [] : node?.actions.dropTypes ?? []
        guard types != registeredDropTypes else { return }
        registeredDropTypes = types
        unregisterDraggedTypes()
        guard !types.isEmpty else { return }
        // Pasteboard types for the content types, plus file URLs (Finder drags of conforming files).
        var pasteboardTypes = types.map { NSPasteboard.PasteboardType($0) }
        pasteboardTypes.append(.fileURL)
        pasteboardTypes.append(.URL)
        pasteboardTypes.append(.string)
        registerForDraggedTypes(pasteboardTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        node?.actions.dropTargeted?(true)
        node?.actions.dropUpdated?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        node?.actions.dropUpdated?(convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        node?.actions.dropTargeted?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        node?.actions.dropTargeted?(false)
        guard let drop = node?.actions.drop else { return false }
        let providers = (sender.draggingPasteboard.pasteboardItems ?? []).map(Self.itemProvider)
        return drop(providers, convert(sender.draggingLocation, from: nil))
    }

    /// `NSItemProvider` for a pasteboard item: file URLs as URLs (with their file types), other
    /// types as data representations.
    private static func itemProvider(_ item: NSPasteboardItem) -> NSItemProvider {
        if let string = item.string(forType: .fileURL), let url = URL(string: string) {
            let provider = NSItemProvider(object: url as NSURL)
            if let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
                provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
            }
            return provider
        }
        let provider = NSItemProvider()
        for type in item.types {
            guard let data = item.data(forType: type) else { continue }
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    // MARK: Drag source

    private var dragStart: NSPoint?

    private func beginDragIfNeeded(_ event: NSEvent) -> Bool {
        guard let makeItem = node?.actions.dragItem, let start = dragStart else { return false }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - start.x, location.y - start.y) > 3 else { return false }
        dragStart = nil
        guard let provider = makeItem() as? NSItemProvider else { return false }
        let writer = NSPasteboardItem()
        let source = ItemProviderPasteboardSource(provider: provider)
        let types = provider.registeredTypeIdentifiers.map { NSPasteboard.PasteboardType($0) }
        writer.setDataProvider(source, forTypes: types)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        item.setDraggingFrame(bounds, contents: image)
        node?.actions.pressed?(false)
        beginDraggingSession(with: [item], event: event, source: self).draggingFormation = .none
        return true
    }

    private func pointer(_ phase: PointerEvent.Phase, _ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        node?.actions.pointer?(PointerEvent(phase: phase, location: location, timestamp: event.timestamp))
    }

    override func mouseUp(with event: NSEvent) {
        guard handlesPointer else { return super.mouseUp(with: event) }
        pointer(.ended, event)
        node?.actions.pressed?(false)
        if isTapTarget, bounds.contains(convert(event.locationInWindow, from: nil)) { node?.actions.primary?() }
    }

    override func mouseDown(with event: NSEvent) {
        if isFocusable { window?.makeFirstResponder(self) }
        guard handlesPointer else { return super.mouseDown(with: event) }
        dragStart = convert(event.locationInWindow, from: nil)
        node?.actions.pressed?(true)
        pointer(.began, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard handlesPointer else { return super.mouseDragged(with: event) }
        if beginDragIfNeeded(event) {
            pointer(.cancelled, event)
            return
        }
        node?.actions.pressed?(bounds.contains(convert(event.locationInWindow, from: nil)))
        pointer(.moved, event)
    }
}

extension EffectNodeView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move, .generic]
    }
}

/// Supplies pasteboard data for a drag from an `NSItemProvider` (loaded on demand).
final class ItemProviderPasteboardSource: NSObject, NSPasteboardItemDataProvider {
    let provider: NSItemProvider
    init(provider: NSItemProvider) { self.provider = provider }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.rawValue) { data, _ in
            result = data
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        if let result { item.setData(result, forType: type) }
    }
}

/// Hosts a representable's NSView, sized to the node frame.
final class RepresentableHostView: FlippedView, PlatformNodeView {
    private weak var hosted: NSView?

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .platformView(let token) = content, let view = token.object as? NSView else { return }
        if hosted !== view {
            hosted?.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            hosted = view
        }
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Replays Canvas drawing commands with Core Graphics.
final class CanvasNodeView: FlippedView, PlatformNodeView {
    private var commands: [DrawCommand] = []

    func apply(_ content: RenderContent, backend: AppKitBackend) {
        guard case .drawing(let commands) = content else { return }
        self.commands = commands
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for command in commands {
            switch command {
            case let .fill(path, paint):
                context.addPath(path.cgPath)
                context.setFillColor(NSColor(paint.colorValue).cgColor)
                context.fillPath()
            case let .stroke(path, paint, style):
                context.addPath(path.cgPath)
                context.setStrokeColor(NSColor(paint.colorValue).cgColor)
                context.setLineWidth(style.lineWidth)
                context.setLineCap(style.lineCap == .round ? .round : style.lineCap == .square ? .square : .butt)
                context.setLineJoin(style.lineJoin == .round ? .round : style.lineJoin == .bevel ? .bevel : .miter)
                if !style.dash.isEmpty { context.setLineDash(phase: style.dashPhase, lengths: style.dash) } else { context.setLineDash(phase: 0, lengths: []) }
                context.strokePath()
            case let .text(text, point, anchor):
                let string = AppKitText.attributedString(text)
                let size = string.size()
                string.draw(at: CGPoint(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y))
            }
        }
    }
}
#endif

#if canImport(AppKit)
extension CATransform3D {
    /// The z = 0 plane transform of a projection (z passes through unchanged).
    init(_ m: ProjectionTransform) {
        self = CATransform3DIdentity
        m11 = m.m11; m12 = m.m12; m14 = m.m13
        m21 = m.m21; m22 = m.m22; m24 = m.m23
        m41 = m.m31; m42 = m.m32; m44 = m.m33
    }
}
#endif
