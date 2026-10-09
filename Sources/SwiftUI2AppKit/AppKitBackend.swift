#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
@_exported import SwiftUI2Core

/// AppKit render backend: one NSView per platform render node, all flipped (top-left origin, like
/// SwiftUI's layout space). Text is measured and drawn with the same attributed strings so layout
/// and rendering always agree.
@MainActor
public final class AppKitBackend: RenderBackend {
    public let rootView: NSView
    public var rootHandle: AnyObject { rootView }

    public init(rootView: NSView) {
        if TextAttributes.platformBridge == nil { AppKitTextAttributeBridge.install() }
        self.rootView = rootView
    }

    // MARK: Rendering

    public func makeView(for node: RenderNode) -> AnyObject {
        let view: NSView & PlatformNodeView
        switch node.content {
        case .text: view = TextNodeView()
        case .color: view = ColorNodeView()
        case .shape: view = ShapeNodeView()
        case .image: view = ImageNodeView()
        case .button: view = ButtonNodeView()
        case .toggle: view = ToggleNodeView()
        case .textField: view = TextFieldNodeView()
        case .slider: view = SliderNodeView()
        case .scrollView: view = ScrollNodeView()
        case .effect(.maskSource): view = MaskSourceNodeView()
        case .effect, .empty: view = EffectNodeView()
        case .datePicker: view = DatePickerNodeView()
        case .colorWell: view = ColorWellNodeView()
        case .drawing: view = CanvasNodeView()
        case .platformView: view = RepresentableHostView()
        }
        view.node = node
        view.apply(node.content, backend: self)
        view.frame = node.frame
        return view
    }

    public func updateContent(of view: AnyObject, node: RenderNode) {
        (view as! PlatformNodeView).apply(node.content, backend: self)
    }

    public func setFrame(of view: AnyObject, node: RenderNode) {
        (view as! NSView).frame = node.frame
    }

    public func setPresentation(of view: AnyObject, node: RenderNode) {
        (view as? FlippedView)?.applyPresentation(node.presentation)
    }

    /// Mask containers whose alpha mask is re-rendered after each commit.
    private let maskedViews = NSHashTable<EffectNodeView>.weakObjects()

    public func didCommit() {
        for view in maskedViews.allObjects { view.refreshMask() }
    }

    public func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) {
        if let effect = view as? EffectNodeView, case .effect(.mask) = node.content {
            // The mask source stays out of the visible hierarchy; it is drawn into the layer mask.
            let views = children.map { $0 as! NSView }
            let visible = views.filter { !($0 is MaskSourceNodeView) }
            if effect.subviews != visible { effect.subviews = visible }
            effect.maskSource = views.last { $0 is MaskSourceNodeView } as? MaskSourceNodeView
            maskedViews.add(effect)
            return
        }
        let container: NSView
        if let scroll = view as? ScrollNodeView {
            container = scroll.documentContainer
        } else {
            container = view as! NSView
        }
        let views = children.map { $0 as! NSView }
        if container.subviews.count == views.count, zip(container.subviews, views).allSatisfy({ $0 === $1 }) { return }
        container.subviews = views
    }

    // MARK: Metrics

    public func unroundedTextWidth(_ text: ResolvedText) -> CGFloat {
        AppKitText.attributedString(text).boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
    }

    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        let string = AppKitText.attributedString(text)
        // Infinite proposals (stack flexibility probes) mean "unconstrained".
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        // Like SwiftUI: line height without the font's leading, sizes rounded up to device pixels.
        var rect = string.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        var usedWidth = min(rect.width, width)
        if let limit = text.lineLimit {
            let lineHeight = AppKitText.lineHeight(text)
            let maxHeight = CGFloat(limit) * lineHeight
            if rect.height > maxHeight + 0.5 {
                // Truncated text uses the whole proposed width (the last line ends in "…").
                rect.size.height = maxHeight
                if width < .greatestFiniteMagnitude { usedWidth = width }
            }
        }
        return CGSize(width: Self.ceilToPixel(usedWidth), height: Self.ceilToPixel(rect.height))
    }

    static let pixelScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    static func ceilToPixel(_ value: CGFloat) -> CGFloat {
        (value * pixelScale - 0.0001).rounded(.up) / pixelScale
    }

    public func firstBaseline(of text: ResolvedText) -> CGFloat {
        AppKitText.font(text.font).ascender.rounded()
    }

    /// SwiftUI's (macOS) text spacing, measured: a view above text keeps `1 + descent` (plus a
    /// half point every 4.25pt of size) from the text's frame; text keeps that plus the
    /// ascender-to-cap distance from a view below; stacked texts are separated by the lower
    /// text's leading (text styles only).
    public func textSpacing(_ font: Font.Resolved) -> TextSpacing? {
        let nsFont = AppKitText.font(font)
        let size = font.size
        let steps = max(0, ((size - 8.5) / 4.25 + 1 + 1e-9).rounded(.down))
        let above = 1 - nsFont.descender + 0.5 * steps
        let below = above + nsFont.ascender - nsFont.capHeight
        var leading: CGFloat = 0
        if let style = font.textStyle {
            leading = Self.ceilToPixel(NSFont.preferredFont(forTextStyle: AppKitText.textStyle(style)).leading)
        }
        return TextSpacing(above: above, below: below, leading: leading)
    }

    public func imageSize(_ image: ResolvedImage) -> CGSize {
        guard let nsImage = AppKitImages.image(image) else { return CGSize(width: image.pointSize, height: image.pointSize) }
        if case .system = image.source {
            // SwiftUI sizes symbols by their vector glyph's content bounds (pixel-rounded); NSImage
            // rounds its size up to whole points.
            if let bounds = Self.symbolContentBounds(nsImage) { return bounds.size }
            return CGSize(width: nsImage.alignmentRect.width, height: nsImage.size.height)
        }
        return nsImage.size
    }

    /// Content bounds of a symbol image's vector glyph (not exposed publicly; read defensively).
    static func symbolContentBounds(_ image: NSImage) -> CGRect? {
        guard let rep = image.representations.first, rep.responds(to: NSSelectorFromString("vectorGlyph")),
              let glyph = rep.value(forKey: "vectorGlyph") as? NSObject,
              glyph.responds(to: NSSelectorFromString("contentBounds")),
              let value = glyph.value(forKey: "contentBounds") as? NSValue else { return nil }
        let bounds = value.rectValue
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
    }

    public func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func share(_ items: [Any]) {
        guard let root = rootHandle as? NSView, let window = root.window else { return }
        // Anchored at the pointer, which is over the share control that was just clicked.
        let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: root, preferredEdge: .minY)
    }

    public func presentFileDialog(_ request: FileDialogRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        let types = request.contentTypes.compactMap { UTType($0) }
        let panel: NSSavePanel
        switch request.kind {
        case .open:
            let open = NSOpenPanel()
            open.allowsMultipleSelection = request.allowsMultipleSelection
            open.canChooseDirectories = request.canChooseDirectories
            open.canChooseFiles = !types.isEmpty ? types.contains { !($0.conforms(to: .directory)) } : true
            panel = open
        case .save:
            panel = NSSavePanel()
            if let name = request.defaultFilename { panel.nameFieldStringValue = name }
        }
        if !types.isEmpty, !types.contains(.data), !types.contains(.item) { panel.allowedContentTypes = types }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let urls = response == .OK ? ((panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] }) : nil
            MainActor.assumeIsolated { completion(urls) }
        }
        if let window = (rootHandle as? NSView)?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    public func controlMetrics(_ control: ControlKind) -> ControlMetrics {
        switch control {
        case .button(let style):
            switch style {
            case .plain, .borderless, .link: return ControlMetrics()
            // SwiftUI's bordered button frame is the 20pt bezel itself (8pt horizontal insets).
            default: return ControlMetrics(contentInsets: EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8), minSize: CGSize(width: 0, height: 20))
            }
        case .checkbox: return ControlMetrics(minSize: CGSize(width: 14, height: 16))
        case .switch: return ControlMetrics(minSize: CGSize(width: 38, height: 22))
        case .textField(let style):
            // Measured on macOS SwiftUI: plain fields are their text line (2pt side insets),
            // bezeled ones add 2.5pt above and below, rounded borders are 22pt tall.
            switch style {
            case .plain: return ControlMetrics(contentInsets: EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2), idealWidth: 96)
            case .roundedBorder: return ControlMetrics(contentInsets: EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 11), idealWidth: 96, fixedHeight: 22)
            case .automatic, .squareBorder: return ControlMetrics(contentInsets: EdgeInsets(top: 2.5, leading: 4.25, bottom: 2.5, trailing: 4.25), idealWidth: 96)
            }
        case .slider: return ControlMetrics(minSize: CGSize(width: 0, height: 20), idealWidth: 0)
        case let .datePicker(date, time):
            // SwiftUI uses the field's intrinsic width (locale dependent) and is 24pt tall.
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            var elements: NSDatePicker.ElementFlags = []
            if date { elements.insert(.yearMonthDay) }
            if time { elements.insert(.hourMinute) }
            picker.datePickerElements = elements
            return ControlMetrics(minSize: CGSize(width: picker.intrinsicContentSize.width, height: 24))
        }
    }
}

// MARK: - Conversions

@MainActor
enum AppKitText {
    static func font(_ font: Font.Resolved) -> NSFont {
        let weight = NSFont.Weight(rawValue: CGFloat(font.weight.value))
        var result: NSFont
        switch font.design {
        case .monospaced: result = .monospacedSystemFont(ofSize: font.size, weight: weight)
        default: result = .systemFont(ofSize: font.size, weight: weight)
        }
        if font.design == .serif || font.design == .rounded,
           let descriptor = result.fontDescriptor.withDesign(font.design == .serif ? .serif : .rounded),
           let designed = NSFont(descriptor: descriptor, size: font.size) {
            result = designed
        }
        if font.italic {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        if font.monospacedDigit {
            result = .monospacedDigitSystemFont(ofSize: font.size, weight: weight)
        }
        return result
    }

    static func attributedString(_ text: ResolvedText) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        switch text.alignment {
        case .leading: paragraph.alignment = .natural
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = .right
        }
        let result = NSMutableAttributedString()
        for run in text.effectiveRuns {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(run.font),
                .foregroundColor: NSColor(run.color),
                .paragraphStyle: paragraph,
            ]
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.tracking != 0 { attributes[.kern] = run.tracking }
            if run.baselineOffset != 0 { attributes[.baselineOffset] = run.baselineOffset }
            if let background = run.background { attributes[.backgroundColor] = NSColor(background) }
            result.append(NSAttributedString(string: run.string, attributes: attributes))
        }
        return result
    }

    static func lineHeight(_ text: ResolvedText) -> CGFloat {
        let line = NSAttributedString(string: "X", attributes: [.font: font(text.font)])
        return line.boundingRect(with: CGSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin]).height
    }

    static func textStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        }
    }
}

@MainActor
enum AppKitImages {
    static func image(_ image: ResolvedImage) -> NSImage? {
        switch image.source {
        case .system(let name):
            let scale: NSImage.SymbolScale = image.scale == .small ? .small : image.scale == .large ? .large : .medium
            let configuration = NSImage.SymbolConfiguration(pointSize: image.pointSize, weight: NSFont.Weight(rawValue: CGFloat(image.weight.value)), scale: scale)
            // Symbol variants that don't exist for a symbol fall back to the closest base name.
            func makeSymbol(_ name: String) -> NSImage? {
                if let value = image.variableValue {
                    return NSImage(systemSymbolName: name, variableValue: value, accessibilityDescription: nil)
                }
                return NSImage(systemSymbolName: name, accessibilityDescription: nil)
            }
            var candidate = name
            var symbol = makeSymbol(candidate)
            while symbol == nil, let dot = candidate.lastIndex(of: ".") {
                candidate = String(candidate[..<dot])
                symbol = makeSymbol(candidate)
            }
            return symbol?.withSymbolConfiguration(configuration)
        case .named(let name):
            return NSImage(named: name)
        case .platform(let platform):
            if let image = platform.object as? NSImage { return image }
            let cgImage = platform.object as! CGImage
            return NSImage(cgImage: cgImage, size: platform.size)
        }
    }
}

extension NSColor {
    convenience init(_ color: Color.Resolved) {
        self.init(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: CGFloat(color.opacity))
    }
}

extension SwiftUI2Core.Path {
    var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case let .quadCurve(p, c): path.addQuadCurve(to: p, control: c)
            case let .curve(p, c1, c2): path.addCurve(to: p, control1: c1, control2: c2)
            case .closeSubpath: path.closeSubpath()
            }
        }
        return path
    }
}
#endif
