import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@_exported import SwiftUI2Core

/// In-memory platform view used by the headless backend.
@MainActor
public final class HeadlessView {
    public internal(set) var frame: CGRect = .zero
    public internal(set) var content: RenderContent = .empty
    public internal(set) var children: [HeadlessView] = []
    public internal(set) weak var superview: HeadlessView?
    public internal(set) weak var node: RenderNode?
    public internal(set) var contentUpdates = 0
    public internal(set) var frameUpdates = 0
    public internal(set) var presentation = RenderPresentation.identity
    public internal(set) var accessibility: AccessibilityProperties?

    init() {}

    /// Frame in root coordinates (scroll offsets ignored).
    public var absoluteFrame: CGRect {
        var origin = frame.origin
        var current = superview
        while let view = current, view.superview != nil {
            origin.x += view.frame.origin.x
            origin.y += view.frame.origin.y
            current = view.superview
        }
        return CGRect(origin: origin, size: frame.size)
    }

    public var text: String? {
        if case .text(let text) = content { return text.string }
        return nil
    }

    public var allDescendants: [HeadlessView] {
        children.flatMap { [$0] + $0.allDescendants }
    }

    public var description: String { dump(indent: 0) }

    func dump(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let f = frame
        var line = "\(pad)\(kindDescription) (\(fmt(f.minX)), \(fmt(f.minY)), \(fmt(f.width)), \(fmt(f.height)))"
        for child in children { line += "\n" + child.dump(indent: indent + 1) }
        return line
    }

    private func fmt(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    var kindDescription: String {
        switch content {
        case .empty: return "root"
        case .text(let text): return "Text \"\(text.string)\""
        case .color: return "Color"
        case .shape: return "Shape"
        case .image(let image): return "Image \(image.source)"
        case .button: return "Button"
        case .toggle(let toggle): return "Toggle(\(toggle.isOn))"
        case .textField(let field): return "TextField \"\(field.text)\""
        case .slider(let slider): return "Slider(\(slider.value))"
        case .scrollView: return "ScrollView"
        case .effect(let effect): return "Effect(\(effect))"
        case .datePicker(let picker): return "DatePicker(\(picker.date))"
        case .colorWell: return "ColorWell"
        case .drawing(let commands): return "Canvas(\(commands.count) commands)"
        case .platformView(let token): return "PlatformView(\(type(of: token.object)))"
        }
    }
}

/// Deterministic backend for tests: monospaced fake text metrics, in-memory views.
@MainActor
public final class HeadlessBackend: RenderBackend {
    public let root = HeadlessView()
    public var rootHandle: AnyObject { root }

    public init() {}

    // MARK: Rendering

    public func makeView(for node: RenderNode) -> AnyObject {
        let view = HeadlessView()
        view.node = node
        view.content = node.content
        view.frame = node.frame
        return view
    }

    public func updateContent(of view: AnyObject, node: RenderNode) {
        let view = view as! HeadlessView
        view.content = node.content
        view.contentUpdates += 1
    }

    public func updateAccessibility(of view: AnyObject, node: RenderNode) {
        (view as! HeadlessView).accessibility = node.accessibility
    }

    public func setFrame(of view: AnyObject, node: RenderNode) {
        let view = view as! HeadlessView
        view.frame = node.frame
        view.frameUpdates += 1
    }

    public func setPresentation(of view: AnyObject, node: RenderNode) {
        (view as! HeadlessView).presentation = node.presentation
    }

    public func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) {
        let view = view as! HeadlessView
        let newChildren = children.map { $0 as! HeadlessView }
        for child in view.children where !newChildren.contains(where: { $0 === child }) { child.superview = nil }
        for child in newChildren { child.superview = view }
        view.children = newChildren
    }

    // MARK: Metrics

    /// Each character is `0.5 × pointSize` wide; lines are `1.2 × pointSize` tall. Words wrap.
    public func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        // `minimumScaleFactor`: the font shrinks (down to the factor) until the text fits the
        // proposed width without exceeding its line limit.
        if text.minimumScaleFactor < 1, let width = proposal.width, width.isFinite {
            let natural = layoutLines(text.string, charWidth: text.font.size * 0.5, maxWidth: nil, lineLimit: nil)
            let longest = CGFloat(natural.map(\.count).max() ?? 0) * text.font.size * 0.5
            if text.lineLimit == 1, longest > width {
                let scale = max(text.minimumScaleFactor, width / longest)
                return measureUnscaled(text.scaled(by: scale), proposal: proposal)
            }
        }
        return measureUnscaled(text, proposal: proposal)
    }

    private func measureUnscaled(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize {
        let charWidth = text.font.size * 0.5
        let lineHeight = (text.font.size * 1.2).rounded(.up)
        let lines = layoutLines(text.string, charWidth: charWidth, maxWidth: proposal.width, lineLimit: text.lineLimit)
        let width = lines.map { CGFloat($0.count) * charWidth }.max() ?? 0
        let count = CGFloat(max(lines.count, 1, text.minimumLines ?? 0))
        return CGSize(width: min(width, proposal.width ?? .infinity).rounded(.up), height: count * lineHeight + (count - 1) * text.lineSpacing)
    }

    func layoutLines(_ string: String, charWidth: CGFloat, maxWidth: CGFloat?, lineLimit: Int?) -> [String] {
        var lines: [String] = []
        for paragraph in string.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let maxWidth, maxWidth.isFinite, charWidth > 0 else {
                lines.append(String(paragraph))
                continue
            }
            let maxChars = max(1, Int(maxWidth / charWidth))
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if candidate.count <= maxChars || current.isEmpty {
                    current = candidate
                } else {
                    lines.append(current)
                    current = String(word)
                }
            }
            lines.append(current)
        }
        if let lineLimit, lines.count > lineLimit { lines = Array(lines.prefix(lineLimit)) }
        return lines
    }

    public func firstBaseline(of text: ResolvedText) -> CGFloat { (text.font.size * 0.95).rounded() }

    public func imageSize(_ image: ResolvedImage) -> CGSize {
        if case .platform(let platform) = image.source { return platform.size }
        let factor: CGFloat = image.scale == .small ? 0.8 : image.scale == .large ? 1.3 : 1
        return CGSize(width: (image.pointSize * factor * 1.25).rounded(), height: (image.pointSize * factor * 1.25).rounded())
    }

    public func controlMetrics(_ control: ControlKind) -> ControlMetrics {
        switch control {
        case .button(let style):
            switch style {
            case .plain, .borderless, .link: return ControlMetrics()
            default: return ControlMetrics(contentInsets: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8), minSize: CGSize(width: 0, height: 22))
            }
        case .checkbox: return ControlMetrics(minSize: CGSize(width: 14, height: 14))
        case .switch: return ControlMetrics(minSize: CGSize(width: 38, height: 22))
        case .textField: return ControlMetrics(contentInsets: EdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4), minSize: CGSize(width: 0, height: 22), idealWidth: 100)
        case .slider: return ControlMetrics(minSize: CGSize(width: 0, height: 20), idealWidth: 100)
        case let .datePicker(date, time, style):
            if style == .graphical { return ControlMetrics(minSize: CGSize(width: 140, height: 150)) }
            return ControlMetrics(minSize: CGSize(width: date && time ? 170 : 100, height: 22))
        }
    }
}
