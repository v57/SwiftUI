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

    public func updateAccessibility(of view: AnyObject, node: RenderNode) {
        (view as? FlippedView)?.applyAccessibility(node.accessibility)
    }

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
        AppKitText.attributedString(text, placeholders: true).boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
    }

    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        // Infinite proposals (stack flexibility probes) mean "unconstrained".
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let text = text.scaled(by: AppKitText.fittingScale(text, width: width))
        let string = AppKitText.attributedString(text, placeholders: true)
        // Like SwiftUI: line height without the font's leading, sizes rounded up to device pixels.
        var rect = string.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        if let minimumLines = text.minimumLines, minimumLines > 1 {
            rect.size.height = max(rect.height, CGFloat(minimumLines) * AppKitText.lineHeight(text))
        }
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
        // Raised runs (`baselineOffset`) make the line taller above the baseline.
        let raise = max(0, text.baselineOffset, text.runs.map(\.baselineOffset).max() ?? 0)
        return AppKitText.font(text.font).ascender.rounded() + raise
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

    /// Distance from a symbol image's bottom to its glyph baseline.
    static func symbolBaselineOffset(_ image: NSImage) -> CGFloat {
        guard let rep = image.representations.first, rep.responds(to: NSSelectorFromString("vectorGlyph")),
              let glyph = rep.value(forKey: "vectorGlyph") as? NSObject,
              glyph.responds(to: NSSelectorFromString("baselineOffset")),
              let value = glyph.value(forKey: "baselineOffset") as? NSNumber else { return 0 }
        return CGFloat(value.doubleValue)
    }

    public func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func readPasteboard() -> [NSItemProvider] { Self.pasteboardProviders() }

    /// The general pasteboard's items as item providers (data loaded eagerly).
    static func pasteboardProviders() -> [NSItemProvider] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
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
    }

    public func writeToPasteboard(_ items: [Any]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = []
        var providers: [NSItemProvider] = []
        for item in items {
            switch item {
            case let string as String: objects.append(string as NSString)
            case let url as URL: objects.append(url as NSURL)
            case let attributed as NSAttributedString: objects.append(attributed)
            case let image as NSImage: objects.append(image)
            case let provider as NSItemProvider: providers.append(provider)
            case let writing as NSPasteboardWriting: objects.append(writing)
            default: objects.append(String(describing: item) as NSString)
            }
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
        // Item providers load asynchronously; their first representation is added when ready.
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first else { continue }
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async {
                    let pasteboardType = NSPasteboard.PasteboardType(type)
                    NSPasteboard.general.addTypes([pasteboardType], owner: nil)
                    NSPasteboard.general.setData(data, forType: pasteboardType)
                }
            }
        }
    }

    public func decodeImage(_ data: Data, scale: CGFloat) -> PlatformImage? {
        guard let image = NSImage(data: data) else { return nil }
        // Pixel-based size divided by the requested scale (like SwiftUI's AsyncImage).
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            image.size = CGSize(width: CGFloat(rep.pixelsWide) / max(scale, 0.01), height: CGFloat(rep.pixelsHigh) / max(scale, 0.01))
        }
        return PlatformImage(object: image, size: image.size)
    }

    public func performHapticFeedback(_ feedback: SensoryFeedback) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch feedback.kind {
        case .alignment, .pathComplete: pattern = .alignment
        case .levelChange, .increase, .decrease, .selection: pattern = .levelChange
        default: pattern = .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
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
        if !types.isEmpty, !types.contains(.data), !types.contains(.item), !types.contains(.folder) { panel.allowedContentTypes = types }
        let options = request.options
        if let message = options.message { panel.message = message }
        if let prompt = options.confirmationLabel { panel.prompt = prompt }
        if let directory = options.defaultDirectory { panel.directoryURL = directory }
        if let label = options.filenameLabel { panel.nameFieldLabel = label }
        if let identifier = options.customizationID { panel.identifier = NSUserInterfaceItemIdentifier(identifier) }
        if let extensions = options.showsFileExtensions { panel.isExtensionHidden = !extensions }
        panel.showsHiddenFiles = options.showsHiddenFiles
        panel.treatsFilePackagesAsDirectories = options.treatsPackagesAsDirectories
        panel.canCreateDirectories = true
        if let open = panel as? NSOpenPanel {
            open.resolvesAliases = !options.importsUnresolvedAliases
            if request.contentTypes == [UTType.folder.identifier] {
                open.canChooseFiles = false
                open.canChooseDirectories = true
            }
        }
        let validator = FilePanelValidator(isEnabled: options.isURLEnabled)
        if options.isURLEnabled != nil { panel.delegate = validator }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = validator
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
        case let .datePicker(date, time, style):
            // SwiftUI uses the field's intrinsic width (locale dependent) and is 24pt tall;
            // graphical pickers are the calendar/clock's intrinsic size.
            let picker = NSDatePicker()
            picker.datePickerStyle = DatePickerNodeView.nativeStyle(style)
            var elements: NSDatePicker.ElementFlags = []
            if date { elements.insert(.yearMonthDay) }
            if time { elements.insert(.hourMinute) }
            picker.datePickerElements = elements
            let size = picker.intrinsicContentSize
            return ControlMetrics(minSize: CGSize(width: size.width, height: style == .graphical ? size.height : 24))
        }
    }
}

// MARK: - Conversions

@MainActor
enum AppKitText {
    static func font(_ font: Font.Resolved) -> NSFont {
        let weight = NSFont.Weight(rawValue: CGFloat(font.weight.value))
        var result: NSFont
        if let name = font.name, let named = NSFont(name: name, size: font.size) {
            result = named
            if font.weight.value >= Font.Weight.semibold.value {
                result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
            }
            if font.italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
            return adjusted(result, font)
        }
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
        if font.monospacedDigit, font.design != .monospaced {
            result = .monospacedDigitSystemFont(ofSize: font.size, weight: weight)
        }
        return adjusted(result, font)
    }

    /// Width axis and small caps.
    private static func adjusted(_ base: NSFont, _ font: Font.Resolved) -> NSFont {
        var descriptor = base.fontDescriptor
        if font.width != 0 {
            descriptor = descriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: font.width]])
        }
        let lowerSmall: [NSFontDescriptor.FeatureKey: Int] = [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]
        let upperSmall: [NSFontDescriptor.FeatureKey: Int] = [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector]
        switch font.caps {
        case .none: break
        case .smallCaps, .lowercaseSmallCaps: descriptor = descriptor.addingAttributes([.featureSettings: [lowerSmall]])
        case .uppercaseSmallCaps: descriptor = descriptor.addingAttributes([.featureSettings: [upperSmall]])
        }
        guard descriptor != base.fontDescriptor else { return base }
        return NSFont(descriptor: descriptor, size: font.size) ?? base
    }

    /// With `placeholders`, inline images take their width but no height (SwiftUI doesn't let
    /// them grow the line); the view draws them over the placeholders (`inlineImageKey`).
    static func attributedString(_ text: ResolvedText, placeholders: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if text.lineLimit == 1 {
            // Single lines truncate where the text asks (multi-line text ends its last line in "…").
            switch text.truncationMode {
            case .head: paragraph.lineBreakMode = .byTruncatingHead
            case .middle: paragraph.lineBreakMode = .byTruncatingMiddle
            case .tail: paragraph.lineBreakMode = .byTruncatingTail
            }
        }
        paragraph.lineSpacing = text.lineSpacing
        paragraph.allowsDefaultTighteningForTruncation = text.allowsTightening
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
            if run.strikethrough {
                attributes[.strikethroughStyle] = lineStyle(run.strikethroughStyle?.pattern).rawValue
                if let color = run.strikethroughStyle?.color { attributes[.strikethroughColor] = NSColor(color) }
            }
            if run.underline {
                attributes[.underlineStyle] = lineStyle(run.underlineStyle?.pattern).rawValue
                if let color = run.underlineStyle?.color { attributes[.underlineColor] = NSColor(color) }
            }
            if run.tracking != 0 { attributes[.kern] = run.tracking }
            if run.baselineOffset != 0 { attributes[.baselineOffset] = run.baselineOffset }
            if let background = run.background { attributes[.backgroundColor] = NSColor(background) }
            if let link = run.link { attributes[.link] = link }
            if let image = run.image, let attachment = attachment(image, font: font(run.font), color: run.color) {
                if placeholders {
                    let placeholder = NSTextAttachment()
                    // An empty image: attachments without contents ignore their bounds.
                    placeholder.image = NSImage(size: NSSize(width: attachment.bounds.width, height: 1))
                    placeholder.bounds = CGRect(x: 0, y: 0, width: attachment.bounds.width, height: 0.001)
                    attributes[inlineImageKey] = attachment
                    let string = NSMutableAttributedString(attachment: placeholder)
                    string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
                    result.append(string)
                    continue
                }
                let string = NSMutableAttributedString(attachment: attachment)
                string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
                result.append(string)
                continue
            }
            result.append(NSAttributedString(string: run.string, attributes: attributes))
        }
        return result
    }

    static let inlineImageKey = NSAttributedString.Key("SwiftUI2InlineImage")

    static func lineStyle(_ pattern: Text.LineStyle.Pattern?) -> NSUnderlineStyle {
        switch pattern ?? .solid {
        case .solid: return .single
        case .dot: return [.single, .patternDot]
        case .dash: return [.single, .patternDash]
        case .dashDot: return [.single, .patternDashDot]
        case .dashDotDot: return [.single, .patternDashDotDot]
        }
    }

    /// `minimumScaleFactor`: the largest font scale (down to the factor) at which single-line
    /// text fits `width`.
    static func fittingScale(_ text: ResolvedText, width: CGFloat) -> CGFloat {
        guard text.minimumScaleFactor < 1, text.lineLimit == 1, width < .greatestFiniteMagnitude else { return 1 }
        var unlimited = text
        unlimited.lineLimit = nil
        let natural = attributedString(unlimited, placeholders: true).size().width
        guard natural > width, natural > 0 else { return 1 }
        // Glyph widths don't scale exactly linearly; step down until it fits.
        var scale = max(text.minimumScaleFactor, width / natural)
        while scale > text.minimumScaleFactor, attributedString(unlimited.scaled(by: scale), placeholders: true).size().width > width {
            scale = max(text.minimumScaleFactor, scale - 0.01)
        }
        return scale
    }

    /// An inline image (symbols take the text color and sit on the baseline like glyphs).
    static func attachment(_ resolved: ResolvedImage, font: NSFont, color: Color.Resolved) -> NSTextAttachment? {
        guard var image = AppKitImages.image(resolved) else { return nil }
        var bounds = CGRect(origin: .zero, size: image.size)
        if case .system = resolved.source {
            let palette = NSImage.SymbolConfiguration(paletteColors: [NSColor(resolved.tint ?? color)])
            if let tinted = image.withSymbolConfiguration(image.symbolConfiguration.applying(palette)) { image = tinted }
            // Symbols sit on the text baseline (their glyph baseline is `baselineOffset` above the
            // image bottom), sized like `Image` views.
            if let content = AppKitBackend.symbolContentBounds(image) { bounds.size = content.size }
            bounds.origin.y = -AppKitBackend.symbolBaselineOffset(image)
        } else {
            bounds.origin.y = (font.capHeight - bounds.height) / 2
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = bounds
        return attachment
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
            var resolvedConfiguration = configuration
            switch image.renderingMode {
            case .hierarchical?:
                if let color = image.paletteColors.first ?? image.tint { resolvedConfiguration = resolvedConfiguration.applying(.init(hierarchicalColor: NSColor(color))) }
            case .palette?:
                if !image.paletteColors.isEmpty { resolvedConfiguration = resolvedConfiguration.applying(.init(paletteColors: image.paletteColors.map { NSColor($0) })) }
            case .multicolor?:
                resolvedConfiguration = resolvedConfiguration.applying(.preferringMulticolor())
            case .monochrome?, nil:
                break
            }
            return symbol?.withSymbolConfiguration(resolvedConfiguration)
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

#endif

/// `fileDialogURLEnabled`: which URLs a panel lets the user pick.
final class FilePanelValidator: NSObject, NSOpenSavePanelDelegate {
    let isEnabled: (@Sendable (URL) -> Bool)?
    init(isEnabled: (@Sendable (URL) -> Bool)?) { self.isEnabled = isEnabled }
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { isEnabled?(url) ?? true }
}
