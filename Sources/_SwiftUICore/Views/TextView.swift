import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Text: View {
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Text>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Text")
        let environment = inputs.environment
        // Relative dates and timers re-resolve every second while shown.
        var clock: Attribute<Date>?
        if AnyAttribute.withoutDependencies({ view.attribute.value.isTimeDependent }) {
            let now = Attribute<Date>(inputs.subgraph, value: Date(), isEqual: { $0 == $1 })
            let timer = Timer(timeInterval: 1, repeats: true) { [weak now] _ in
                MainActor.assumeIsolated { now?.setValue(Date()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            inputs.subgraph.onDestroy { timer.invalidate() }
            clock = now
        }
        let resolved = Attribute<ResolvedText>(inputs.subgraph, isEqual: { $0 == $1 }) {
            _ = clock?.value
            return view.attribute.value.resolve(in: environment.value)
        }
        resolved.setLabel("resolved \(inputs.path)")
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) { .text(resolved.value) }
        var actions = RenderActions()
        actions.openURL = { url in AnyAttribute.withoutDependencies { environment.value.openURL(url) } }
        inputs.makePlatformNode(content: content, actions: actions)

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

    /// Natural sizes by proposed width: text measures by width alone (no backend reads the proposed
    /// height), and stacks probe each width with many heights (0, ∞, the share of each parent's
    /// probe), so one text was measured some twenty times per build.
    private var natural: [(width: CGFloat?, size: CGSize)] = []

    private func naturalSize(width: CGFloat?) -> CGSize {
        if let hit = natural.first(where: { $0.width == width }) { return hit.size }
        let size = services.measureText(text, proposal: ProposedViewSize(width: width, height: nil))
        if natural.count >= 8 { natural.removeFirst() }
        natural.append((width, size))
        return size
    }

    /// One line's height and line-limited sizes, by width (heights below the natural one keep
    /// as many lines as fit).
    private var lineHeights: [(width: CGFloat?, height: CGFloat)] = []
    private var limitedSizes: [(width: CGFloat?, lines: Int, size: CGSize)] = []

    private func lineHeight(width proposedWidth: CGFloat?) -> CGFloat {
        // One line is as tall at any width, unless the font shrinks to fit it.
        let width = text.minimumScaleFactor < 1 ? proposedWidth : nil
        if let hit = lineHeights.first(where: { $0.width == width }) { return hit.height }
        var line = text
        line.lineLimit = 1
        let height = services.measureText(line, proposal: ProposedViewSize(width: width, height: nil)).height
        if lineHeights.count >= 4 { lineHeights.removeFirst() }
        lineHeights.append((width, height))
        return height
    }

    private func limitedSize(width: CGFloat?, lines: Int) -> CGSize {
        if let hit = limitedSizes.first(where: { $0.width == width && $0.lines == lines }) { return hit.size }
        var limited = text
        limited.lineLimit = lines
        let size = services.measureText(limited, proposal: ProposedViewSize(width: width, height: nil))
        if limitedSizes.count >= 8 { limitedSizes.removeFirst() }
        limitedSizes.append((width, lines, size))
        return size
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let size = naturalSize(width: proposal.width)
        // SwiftUI: text shows only as many lines as fit the proposed height (at least one).
        guard let height = proposal.height, height.isFinite, size.height > height, (text.lineLimit ?? 2) > 1 else { return size }
        let lineHeight = lineHeight(width: proposal.width)
        // A single line has no line to drop.
        guard lineHeight > 0, size.height > lineHeight + 0.5 else { return size }
        // Reserved lines (`reservesSpace`, line limit ranges) are kept even when squeezed.
        let lines = max(text.minimumLines ?? 1, 1, Int(((height + 0.01) / lineHeight).rounded(.down)))
        return limitedSize(width: proposal.width, lines: lines)
    }

    override var computedSpacing: ViewSpacing {
        services.textSpacing(text.font).map(ViewSpacing.text) ?? .default
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        guard key.axis == .vertical else { return nil }
        if key == VerticalAlignment.firstTextBaseline.key {
            return services.firstBaseline(of: text)
        }
        if key == VerticalAlignment.lastTextBaseline.key {
            return size.height - (naturalSize(width: nil).height - services.firstBaseline(of: text))
        }
        return nil
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? TextLayoutComputer else { return false }
        return other.text.layoutKey == text.layoutKey
    }
}
