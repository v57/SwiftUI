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

    public func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) {
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

    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        let string = AppKitText.attributedString(text)
        // Infinite proposals (stack flexibility probes) mean "unconstrained".
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        // Like SwiftUI: line height without the font's leading, sizes rounded up to device pixels.
        var rect = string.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        if let limit = text.lineLimit {
            let lineHeight = AppKitText.lineHeight(text)
            rect.size.height = min(rect.height, CGFloat(limit) * lineHeight)
        }
        return CGSize(width: Self.ceilToPixel(min(rect.width, width)), height: Self.ceilToPixel(rect.height))
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
        AppKitImages.image(image)?.size ?? CGSize(width: image.pointSize, height: image.pointSize)
    }

    public func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
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
        case .checkbox: return ControlMetrics(minSize: CGSize(width: 16, height: 16))
        case .switch: return ControlMetrics(minSize: CGSize(width: 38, height: 22))
        case .textField: return ControlMetrics(minSize: CGSize(width: 0, height: 21), idealWidth: 96)
        case .slider: return ControlMetrics(minSize: CGSize(width: 0, height: 21), idealWidth: 96)
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
            let configuration = NSImage.SymbolConfiguration(pointSize: image.pointSize, weight: NSFont.Weight(rawValue: CGFloat(image.weight.value)))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        case .named(let name):
            return NSImage(named: name)
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
