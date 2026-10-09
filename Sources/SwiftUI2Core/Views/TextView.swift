import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Text: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Text>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Text")
        let environment = inputs.environment
        let resolved = Attribute<ResolvedText>(inputs.subgraph, isEqual: { $0 == $1 }) {
            view.attribute.value.resolve(in: environment.value)
        }
        resolved.label = "resolved \(inputs.path)"
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) { .text(resolved.value) }
        inputs.makePlatformNode(content: content)

        // A new computer is created when the resolved text changes, but `isEquivalent` compares only
        // the layout-relevant part: a color change never invalidates the parent's layout.
        let services = inputs.services
        let tracer = inputs.tracer
        let path = inputs.path
        let layout = inputs.makeLayoutAttribute {
            TextLayoutComputer(text: resolved.value, services: services, path: path, tracer: tracer)
        }
        return _ViewOutputs(layout: layout)
    }
}

final class TextLayoutComputer: LayoutComputer {
    let text: ResolvedText
    unowned let services: any PlatformServices

    init(text: ResolvedText, services: any PlatformServices, path: ViewPath, tracer: UpdateTracer) {
        self.text = text
        self.services = services
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let size = services.measureText(text, proposal: proposal)
        // SwiftUI: text shows only as many lines as fit the proposed height (at least one).
        guard let height = proposal.height, height.isFinite, size.height > height, (text.lineLimit ?? 2) > 1 else { return size }
        var line = text
        line.lineLimit = 1
        let lineHeight = services.measureText(line, proposal: ProposedViewSize(width: proposal.width, height: nil)).height
        guard lineHeight > 0 else { return size }
        var limited = text
        limited.lineLimit = max(1, Int(((height + 0.01) / lineHeight).rounded(.down)))
        return services.measureText(limited, proposal: proposal)
    }

    override var spacing: ViewSpacing {
        services.textSpacing(text.font).map(ViewSpacing.text) ?? .default
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        guard key.axis == .vertical else { return nil }
        if key == VerticalAlignment.firstTextBaseline.key {
            return services.firstBaseline(of: text)
        }
        if key == VerticalAlignment.lastTextBaseline.key {
            return size.height - (services.measureText(text, proposal: .unspecified).height - services.firstBaseline(of: text))
        }
        return nil
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? TextLayoutComputer else { return false }
        return other.text.layoutKey == text.layoutKey
    }
}
