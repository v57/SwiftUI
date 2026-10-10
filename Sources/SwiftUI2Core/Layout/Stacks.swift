import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared HStack/VStack algorithm (mirrors SwiftUI's): children are offered space in order of
/// descending layout priority and, within a priority, ascending flexibility.
@MainActor
struct StackAlgorithm {
    let axis: Axis
    let spacing: CGFloat?

    func spacings(_ subviews: LayoutSubviews) -> [CGFloat] {
        guard subviews.count > 1 else { return [] }
        return (0..<(subviews.count - 1)).map { index in
            if let spacing {
                // Explicit spacing still collapses around spacers? No: SwiftUI applies it everywhere.
                return spacing
            }
            return subviews[index].spacing.distance(to: subviews[index + 1].spacing, along: axis)
        }
    }

    func childSizes(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews, spacings: [CGFloat]) -> [CGSize] {
        let cross = proposal[axis.other]
        guard let main = proposal[axis], main.isFinite else {
            let mainProposal = proposal[axis]
            return subviews.map { $0.sizeThatFits(ProposedViewSize(main: mainProposal, cross: cross, axis: axis)) }
        }
        var remaining = max(0, main - spacings.reduce(0, +))
        let count = subviews.count
        let mins = subviews.map { $0.sizeThatFits(ProposedViewSize(main: 0, cross: cross, axis: axis))[axis] }
        let maxs = subviews.map { $0.sizeThatFits(ProposedViewSize(main: .infinity, cross: cross, axis: axis))[axis] }
        var sizes = Array(repeating: CGSize.zero, count: count)
        let priorities = Array(Set(subviews.map(\.priority))).sorted(by: >)
        for priority in priorities {
            let group = (0..<count).filter { subviews[$0].priority == priority }
            let lowerMinimums = (0..<count).reduce(CGFloat(0)) { sum, index in
                subviews[index].priority < priority ? sum + mins[index] : sum
            }
            var available = remaining - lowerMinimums
            var used: CGFloat = 0
            // Views are offered space before spacers (least flexible first); spacers take what is
            // left, so `Text` + `Spacer` gives the text everything but the spacer's minimum.
            let views = group.filter { !subviews[$0].isSpacer }.sorted { (maxs[$0] - mins[$0], $0) < (maxs[$1] - mins[$1], $1) }
            let spacers = group.filter { subviews[$0].isSpacer }
            var spacerReserve = spacers.reduce(CGFloat(0)) { $0 + mins[$1] }
            var left = views.count
            for index in views {
                let share = max(0, (available - spacerReserve) / CGFloat(left))
                let size = subviews[index].sizeThatFits(ProposedViewSize(main: share, cross: cross, axis: axis))
                sizes[index] = size
                available -= size[axis]
                used += size[axis]
                left -= 1
            }
            left = spacers.count
            for index in spacers {
                spacerReserve -= mins[index]
                let share = max(0, available / CGFloat(left))
                let size = subviews[index].sizeThatFits(ProposedViewSize(main: share, cross: cross, axis: axis))
                sizes[index] = size
                available -= size[axis]
                used += size[axis]
                left -= 1
            }
            remaining -= used
        }
        return sizes
    }

    func sizeThatFits(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let spacings = spacings(subviews)
        let sizes = childSizes(proposal, subviews, spacings: spacings)
        let main = sizes.reduce(0) { $0 + $1[axis] } + spacings.reduce(0, +)
        let cross = sizes.reduce(0) { max($0, $1[axis.other]) }
        return CGSize(main: main, cross: cross, axis: axis)
    }

    func place(in bounds: CGRect, proposal original: ProposedViewSize, _ subviews: LayoutSubviews, crossGuide: (AlignmentKey, any AlignmentID.Type)) {
        guard !subviews.isEmpty else { return }
        let spacings = spacings(subviews)
        // Re-run the allocation with the proposal the stack was sized for (not its bounds), so
        // placement agrees with sizeThatFits (SwiftUI does the same).
        var proposal = original
        if proposal[axis.other] == nil { proposal[axis.other] = bounds.size[axis.other] }
        let sizes = childSizes(proposal, subviews, spacings: spacings)
        let alignmentValues = subviews.indices.map { index -> CGFloat in
            subviews[index].computer.dimensions(size: sizes[index])[crossGuide.0, crossGuide.1]
        }
        let line = alignmentValues.max() ?? 0
        var position = bounds.origin[axis]
        let crossOrigin = bounds.origin[axis.other]
        for index in subviews.indices {
            let size = sizes[index]
            let point = axis == .horizontal
                ? CGPoint(x: position, y: crossOrigin + line - alignmentValues[index])
                : CGPoint(x: crossOrigin + line - alignmentValues[index], y: position)
            subviews[index].place(at: point, anchor: .topLeading, proposal: ProposedViewSize(main: size[axis], cross: proposal[axis.other], axis: axis))
            position += size[axis] + (index < spacings.count ? spacings[index] : 0)
        }
    }
}

public struct _VStackLayout: Layout, Equatable {
    public var alignment: HorizontalAlignment
    public var spacing: CGFloat?

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .vertical
        return properties
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        StackAlgorithm(axis: .vertical, spacing: spacing).sizeThatFits(proposal, subviews)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        StackAlgorithm(axis: .vertical, spacing: spacing).place(in: bounds, proposal: proposal, subviews, crossGuide: (alignment.key, alignment.id))
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing {
        stackSpacing(subviews, axis: .vertical)
    }
}

public struct _HStackLayout: Layout, Equatable {
    public var alignment: VerticalAlignment
    public var spacing: CGFloat?

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .horizontal
        return properties
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        StackAlgorithm(axis: .horizontal, spacing: spacing).sizeThatFits(proposal, subviews)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        StackAlgorithm(axis: .horizontal, spacing: spacing).place(in: bounds, proposal: proposal, subviews, crossGuide: (alignment.key, alignment.id))
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing {
        stackSpacing(subviews, axis: .horizontal)
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? {
        // Text baselines propagate out of an HStack (first child that has one).
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let algorithm = StackAlgorithm(axis: .horizontal, spacing: spacing)
        let sizes = algorithm.childSizes(ProposedViewSize(bounds.size), subviews, spacings: algorithm.spacings(subviews))
        let line = subviews.indices.map { subviews[$0].computer.dimensions(size: sizes[$0])[alignment] }.max() ?? 0
        for index in subviews.indices {
            let dimensions = subviews[index].computer.dimensions(size: sizes[index])
            if let baseline = dimensions[explicit: guide] {
                return line - dimensions[alignment] + baseline
            }
        }
        return nil
    }
}

public struct _ZStackLayout: Layout, Equatable {
    public var alignment: Alignment
    public init(alignment: Alignment = .center) { self.alignment = alignment }

    /// Children's frames with their alignment guides at the origin (SwiftUI sizes a ZStack to
    /// the union of these, so alignment guides can make it larger than any child).
    private func alignedFrames(_ subviews: Subviews, proposal: ProposedViewSize) -> [CGRect] {
        subviews.map { subview in
            let size = subview.sizeThatFits(proposal)
            let dimensions = subview.computer.dimensions(size: size)
            return CGRect(x: -dimensions[alignment.horizontal], y: -dimensions[alignment.vertical], width: size.width, height: size.height)
        }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let union = alignedFrames(subviews, proposal: proposal).reduce(nil, { (result: CGRect?, frame) in result?.union(frame) ?? frame }) else { return .zero }
        return union.size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Children are proposed the stack's size (a flexible child fills it).
        let placement = ProposedViewSize(bounds.size)
        let frames = alignedFrames(subviews, proposal: placement)
        guard let union = frames.reduce(nil, { (result: CGRect?, frame) in result?.union(frame) ?? frame }) else { return }
        let fx = _LazyGridLayout.fraction(alignment.horizontal), fy = _LazyGridLayout.fraction(alignment.vertical)
        let origin = CGPoint(x: bounds.minX + (bounds.width - union.width) * fx - union.minX, y: bounds.minY + (bounds.height - union.height) * fy - union.minY)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY), proposal: placement)
        }
    }
}

@MainActor
private func stackSpacing(_ subviews: LayoutSubviews, axis: Axis) -> ViewSpacing {
    guard let first = subviews.first, let last = subviews.last else { return .zero }
    var result = ViewSpacing.empty
    for subview in subviews { result.formUnion(subview.spacing, edges: axis == .vertical ? .horizontal : .vertical) }
    result.formUnion(first.spacing, edges: axis == .vertical ? .top : .leading)
    result.formUnion(last.spacing, edges: axis == .vertical ? .bottom : .trailing)
    result.isSpacer = false
    return result
}

public typealias VStackLayout = _VStackLayout
public typealias HStackLayout = _HStackLayout
public typealias ZStackLayout = _ZStackLayout

// MARK: - Stack views

public struct VStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "VStack")
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs)
        let layout = view.project(inputs) { _VStackLayout(alignment: $0.alignment, spacing: $0.spacing) }
        return inputs.makeLayoutContainer(layout: layout.attribute, list: list.list)
    }
}

public struct HStack<Content: View>: View {
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "HStack")
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs)
        let layout = view.project(inputs) { _HStackLayout(alignment: $0.alignment, spacing: $0.spacing) }
        return inputs.makeLayoutContainer(layout: layout.attribute, list: list.list)
    }
}

public struct ZStack<Content: View>: View {
    let alignment: Alignment
    let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "ZStack")
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs)
        let layout = view.project(inputs) { _ZStackLayout(alignment: $0.alignment) }
        return inputs.makeLayoutContainer(layout: layout.attribute, list: list.list)
    }
}


// MARK: - Spacer / Divider

public struct Spacer: View, Equatable {
    public var minLength: CGFloat?
    public init(minLength: CGFloat? = nil) { self.minLength = minLength }
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let axis = inputs.stackAxis
        let tracer = inputs.tracer
        let path = inputs.path.appending("Spacer")
        let layout = inputs.makeLayoutAttribute {
            SpacerComputer(minLength: view.attribute.value.minLength ?? 8, axis: axis, path: path, tracer: tracer)
        }
        return _ViewOutputs(layout: layout)
    }
}

final class SpacerComputer: LayoutComputer {
    let minLength: CGFloat
    let axis: Axis?

    init(minLength: CGFloat, axis: Axis?, path: ViewPath, tracer: UpdateTracer) {
        self.minLength = minLength
        self.axis = axis
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        func expand(_ value: CGFloat?) -> CGFloat { max(minLength, value ?? minLength) }
        switch axis {
        case .horizontal?: return CGSize(width: expand(proposal.width), height: 0)
        case .vertical?: return CGSize(width: 0, height: expand(proposal.height))
        case nil: return CGSize(width: expand(proposal.width), height: expand(proposal.height))
        }
    }

    override var spacing: ViewSpacing { .spacer }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? SpacerComputer else { return false }
        return other.minLength == minLength && other.axis == axis
    }
}

public struct Divider: View, Equatable {
    public init() {}
    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "Divider")
        let axis = inputs.stackAxis ?? .vertical
        let tracer = inputs.tracer
        let path = inputs.path
        let layout = inputs.makeLayoutAttribute { DividerComputer(stackAxis: axis, path: path, tracer: tracer) }
        let environment = inputs.environment
        let content = Attribute<RenderContent>(inputs.subgraph) {
            .color(Color.separator.resolve(in: environment.value))
        }
        inputs.makePlatformNode(content: content)
        return _ViewOutputs(layout: layout)
    }
}

final class DividerComputer: LayoutComputer {
    let stackAxis: Axis
    init(stackAxis: Axis, path: ViewPath, tracer: UpdateTracer) {
        self.stackAxis = stackAxis
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        stackAxis == .vertical
            ? CGSize(width: proposal.width ?? 0, height: 1)
            : CGSize(width: 1, height: proposal.height ?? 0)
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        (other as? DividerComputer)?.stackAxis == stackAxis
    }
}
