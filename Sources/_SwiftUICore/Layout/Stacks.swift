import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Shared HStack/VStack algorithm (mirrors SwiftUI's): children are offered space in order of
/// descending layout priority and, within a priority, ascending flexibility.
///
/// Nonisolated, with loops rather than closures: a main-actor closure passed to the standard
/// library checks the executor on every call, and stacks call them per child and per probe.
nonisolated struct StackAlgorithm {
    let axis: Axis
    let spacing: CGFloat?

    func spacings(_ subviews: LayoutSubviews) -> [CGFloat] {
        guard subviews.count > 1 else { return [] }
        var result: [CGFloat] = []
        result.reserveCapacity(subviews.count - 1)
        // Explicit spacing applies everywhere (SwiftUI doesn't collapse it around spacers).
        if let spacing {
            for _ in 0..<(subviews.count - 1) { result.append(spacing) }
            return result
        }
        var previous = subviews[0].spacing
        for index in 1..<subviews.count {
            let next = subviews[index].spacing
            result.append(previous.distance(to: next, along: axis))
            previous = next
        }
        return result
    }

    func childSizes(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews, spacings: [CGFloat]) -> [CGSize] {
        let cross = proposal[axis.other]
        let count = subviews.count
        var sizes = [CGSize](repeating: .zero, count: count)
        guard let main = proposal[axis], main.isFinite else {
            let childProposal = ProposedViewSize(main: proposal[axis], cross: cross, axis: axis)
            for index in 0..<count { sizes[index] = subviews[index].sizeThatFits(childProposal) }
            return sizes
        }
        var spacingTotal: CGFloat = 0
        for value in spacings { spacingTotal += value }
        var remaining = max(0, main - spacingTotal)
        var mins = [CGFloat](repeating: 0, count: count)
        var maxs = [CGFloat](repeating: 0, count: count)
        var priorities = [Double](repeating: 0, count: count)
        var isSpacer = [Bool](repeating: false, count: count)
        let minProposal = ProposedViewSize(main: 0, cross: cross, axis: axis)
        let maxProposal = ProposedViewSize(main: .infinity, cross: cross, axis: axis)
        for index in 0..<count { mins[index] = subviews[index].sizeThatFits(minProposal)[axis] }
        for index in 0..<count { maxs[index] = subviews[index].sizeThatFits(maxProposal)[axis] }
        var uniform = true
        for index in 0..<count {
            priorities[index] = subviews[index].priority
            isSpacer[index] = subviews[index].isSpacer
            if priorities[index] != priorities[0] { uniform = false }
        }
        let distinctPriorities = uniform ? (count > 0 ? [priorities[0]] : []) : Array(Set(priorities)).sorted(by: >)
        var views: [Int] = []
        var spacers: [Int] = []
        views.reserveCapacity(count)
        for priority in distinctPriorities {
            var lowerMinimums: CGFloat = 0
            views.removeAll(keepingCapacity: true)
            spacers.removeAll(keepingCapacity: true)
            for index in 0..<count {
                if priorities[index] < priority { lowerMinimums += mins[index] }
                guard priorities[index] == priority else { continue }
                if isSpacer[index] { spacers.append(index) } else { views.append(index) }
            }
            var available = remaining - lowerMinimums
            var used: CGFloat = 0
            // Views are offered space before spacers (least flexible first); spacers take what is
            // left, so `Text` + `Spacer` gives the text everything but the spacer's minimum.
            views.sort { (maxs[$0] - mins[$0], $0) < (maxs[$1] - mins[$1], $1) }
            var spacerReserve: CGFloat = 0
            for index in spacers { spacerReserve += mins[index] }
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

    func sizeThatFits(_ proposal: ProposedViewSize, _ subviews: LayoutSubviews, crossGuide: AlignmentKey? = nil) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let spacings = spacings(subviews)
        let sizes = childSizes(proposal, subviews, spacings: spacings)
        var main: CGFloat = 0
        var cross: CGFloat = 0
        for size in sizes {
            main += size[axis]
            cross = max(cross, size[axis.other])
        }
        for value in spacings { main += value }
        if let crossGuide, subviews.count > 1 {
            // Children are aligned on the guide: the stack spans the union of their extents
            // (alignment guides can make it larger than any child).
            var above: CGFloat = 0
            var below: CGFloat = 0
            for index in 0..<subviews.count {
                let value = subviews[index].alignment(crossGuide, size: sizes[index])
                above = max(above, value)
                below = max(below, sizes[index][axis.other] - value)
            }
            cross = max(cross, above + below)
        }
        return CGSize(main: main, cross: cross, axis: axis)
    }

    func place(in bounds: CGRect, proposal original: ProposedViewSize, _ subviews: LayoutSubviews, crossGuide: AlignmentKey) {
        guard !subviews.isEmpty else { return }
        let spacings = spacings(subviews)
        // Re-run the allocation with the proposal the stack was sized for (not its bounds), so
        // placement agrees with sizeThatFits (SwiftUI does the same).
        var proposal = original
        if proposal[axis.other] == nil { proposal[axis.other] = bounds.size[axis.other] }
        let sizes = childSizes(proposal, subviews, spacings: spacings)
        var alignmentValues = [CGFloat](repeating: 0, count: subviews.count)
        var line: CGFloat = 0
        for index in 0..<subviews.count {
            let value = subviews[index].alignment(crossGuide, size: sizes[index])
            alignmentValues[index] = value
            line = index == 0 ? value : max(line, value)
        }
        var position = bounds.origin[axis]
        let crossOrigin = bounds.origin[axis.other]
        for index in 0..<subviews.count {
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
        StackAlgorithm(axis: .vertical, spacing: spacing).sizeThatFits(proposal, subviews, crossGuide: alignment.key)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        StackAlgorithm(axis: .vertical, spacing: spacing).place(in: bounds, proposal: proposal, subviews, crossGuide: alignment.key)
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing {
        stackSpacing(subviews, axis: .vertical)
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? {
        // The first (last) child's text baseline is the stack's first (last) baseline.
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let algorithm = StackAlgorithm(axis: .vertical, spacing: spacing)
        let spacings = algorithm.spacings(subviews)
        let sizes = algorithm.childSizes(ProposedViewSize(bounds.size), subviews, spacings: spacings)
        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        for index in subviews.indices {
            offsets.append(y)
            y += sizes[index].height + (index < spacings.count ? spacings[index] : 0)
        }
        let order = guide == .firstTextBaseline ? Array(subviews.indices) : subviews.indices.reversed()
        for index in order {
            if let baseline = subviews[index].computer.dimensions(size: sizes[index])[explicit: guide] {
                return offsets[index] + baseline
            }
        }
        return nil
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
        StackAlgorithm(axis: .horizontal, spacing: spacing).sizeThatFits(proposal, subviews, crossGuide: alignment.key)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        StackAlgorithm(axis: .horizontal, spacing: spacing).place(in: bounds, proposal: proposal, subviews, crossGuide: alignment.key)
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
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        let horizontal = alignment.horizontal.key, vertical = alignment.vertical.key
        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            frames.append(CGRect(x: -subview.alignment(horizontal, size: size), y: -subview.alignment(vertical, size: size), width: size.width, height: size.height))
        }
        return frames
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        guard var result = frames.first else { return nil }
        for frame in frames.dropFirst() { result = result.union(frame) }
        return result
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        Self.union(alignedFrames(subviews, proposal: proposal))?.size ?? .zero
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        // Children are proposed the stack's size (a flexible child fills it).
        let placement = ProposedViewSize(bounds.size)
        let frames = alignedFrames(subviews, proposal: placement)
        guard let union = Self.union(frames) else { return }
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

    override var computedSpacing: ViewSpacing { .spacer }

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
