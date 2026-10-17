import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The measurement side of a view: answers size and alignment queries. A view's layout computer is
/// an attribute; it is replaced only when something affecting measurement changed, and
/// `isEquivalent(to:)` lets a computer declare that a change does not affect its *parent*
/// (layout boundaries: fixed frames, overlays, scroll views, geometry readers).
@MainActor
public class LayoutComputer {
    let path: ViewPath?
    unowned let tracer: UpdateTracer
    private var sizeCache: [(ProposedViewSize, CGSize)] = []

    init(path: ViewPath?, tracer: UpdateTracer) {
        self.path = path
        self.tracer = tracer
    }

    public final func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        for (cachedProposal, size) in sizeCache where cachedProposal == proposal { return size }
        let size = computeSize(proposal)
        tracer.record(.sizeThatFits, path)
        if sizeCache.count >= 32 { sizeCache.removeFirst() }
        sizeCache.append((proposal, size))
        return size
    }

    func computeSize(_ proposal: ProposedViewSize) -> CGSize { .zero }

    /// The sizes this computer has answered so far (most recent proposals).
    final var answeredSizes: [(ProposedViewSize, CGSize)] { sizeCache }

    /// Explicit value for an alignment guide, in the view's own coordinate space.
    func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? { nil }

    final func dimensions(in proposal: ProposedViewSize) -> ViewDimensions {
        let size = sizeThatFits(proposal)
        return ViewDimensions(size: size) { [self] key in explicitAlignment(key, in: size) }
    }

    final func dimensions(size: CGSize) -> ViewDimensions {
        ViewDimensions(size: size) { [self] key in explicitAlignment(key, in: size) }
    }

    /// The view's spacing preferences, computed once per computer (computers are immutable
    /// snapshots; a container's spacing is the union of its children's, so recomputing it on
    /// every query walked whole subtrees).
    final var spacing: ViewSpacing {
        if let spacingCache { return spacingCache }
        let value = computedSpacing
        tracer.counters.spacingComputations += 1
        spacingCache = value
        return value
    }
    private var spacingCache: ViewSpacing?
    var computedSpacing: ViewSpacing { .default }
    var layoutPriority: Double { 0 }
    func layoutValue(_ key: ObjectIdentifier) -> Any? { nil }

    /// Whether replacing `other` (the previous computer of the same view) by `self` is invisible to
    /// the parent's layout.
    func isEquivalent(to other: LayoutComputer) -> Bool { self === other }

    static func equivalence(_ lhs: LayoutComputer, _ rhs: LayoutComputer) -> Bool {
        rhs.isEquivalent(to: lhs)
    }
}

/// Zero-size, used by EmptyView.
final class EmptyLayoutComputer: LayoutComputer {
    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { .zero }
    override var computedSpacing: ViewSpacing { .zero }
    override func isEquivalent(to other: LayoutComputer) -> Bool { other is EmptyLayoutComputer }
}

/// Takes the proposed size (10x10 for unspecified dimensions) — Color, shapes, GeometryReader.
final class FlexibleLayoutComputer: LayoutComputer {
    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    override func isEquivalent(to other: LayoutComputer) -> Bool { other is FlexibleLayoutComputer }
}

/// Wraps a single child, forwarding queries (base for unary layout modifiers).
class UnaryLayoutComputer: LayoutComputer {
    let child: LayoutComputer

    init(child: LayoutComputer, path: ViewPath?, tracer: UpdateTracer) {
        self.child = child
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { child.sizeThatFits(proposal) }
    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? { child.explicitAlignment(key, in: size) }
    override var computedSpacing: ViewSpacing { child.spacing }
    override var layoutPriority: Double { child.layoutPriority }
    override func layoutValue(_ key: ObjectIdentifier) -> Any? { child.layoutValue(key) }

    /// Geometry of the child when this view is placed at `geometry`.
    func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        ViewGeometry(origin: geometry.origin, size: geometry.size, proposal: geometry.proposal)
    }

    /// Default: same modifier parameters and the same child.
    func hasSameParameters(as other: LayoutComputer) -> Bool { false }

    /// Whether `other` places the same child in the same way (cuts off placement work).
    final func isSamePlacement(as other: LayoutComputer) -> Bool {
        if other === self { return true }
        guard let other = other as? UnaryLayoutComputer, type(of: other) == type(of: self), other.child === child else { return false }
        return hasSameParameters(as: other)
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? UnaryLayoutComputer, type(of: other) == type(of: self) else { return false }
        return other.child === child && hasSameParameters(as: other)
    }
}

extension ViewGeometry {
    /// Places a child of `childSize` inside `self` using `alignment` (alignment guides of both).
    @MainActor
    func aligning(childSize: CGSize, child: LayoutComputer, container: ViewDimensions, alignment: Alignment, proposal: ProposedViewSize) -> ViewGeometry {
        let childDimensions = child.dimensions(size: childSize)
        let x = container[alignment.horizontal] - childDimensions[alignment.horizontal]
        let y = container[alignment.vertical] - childDimensions[alignment.vertical]
        return ViewGeometry(origin: CGPoint(x: origin.x + x, y: origin.y + y), size: childSize, proposal: proposal)
    }
}

@MainActor
extension _ViewInputs {
    /// Builds a layout modifier with one child: the child gets a late-bound geometry computed by
    /// `computer.placeChild`, and the modifier exposes `computer` as its layout.
    func makeUnaryLayout(
        component: String,
        body: (_ViewInputs) -> _ViewOutputs,
        computer makeComputer: @escaping @MainActor (LayoutComputer, ViewPath) -> UnaryLayoutComputer
    ) -> _ViewOutputs {
        let modifierPath = path.appending(component)
        let childGeometry = makeChildGeometry(label: "geometry \(modifierPath)")
        var childInputs = self
        childInputs.geometry = childGeometry
        childInputs.depth += 1
        let childOutputs = body(childInputs)
        let childLayout = childOutputs.layout
        // Placement needs the current parameters (e.g. a new offset), while the parent only sees a
        // change when the computer is not equivalent (equivalent computers keep the old instance).
        let current = Attribute<LayoutComputer>(subgraph, isEqual: { ($1 as! UnaryLayoutComputer).isSamePlacement(as: $0) }) {
            makeComputer(childLayout.value, modifierPath)
        }
        current.setLabel("current layout \(modifierPath)")
        let layout = Attribute<LayoutComputer>(subgraph, isEqual: LayoutComputer.equivalence) { current.value }
        layout.setLabel("layout \(modifierPath)")
        let geometry = self.geometry
        let tracer = self.tracer
        childGeometry.setRule {
            let computer = current.value as! UnaryLayoutComputer
            tracer.record(.placement, modifierPath)
            return computer.placeChild(in: geometry.value, child: childLayout.value)
        }
        let childPath = path
        childGeometry.onChange = { _ in tracer.record(.geometry, childPath) }
        return _ViewOutputs(layout: layout, preferences: childOutputs.preferences)
    }

    func makeLayoutAttribute(_ make: @escaping @MainActor () -> LayoutComputer) -> Attribute<LayoutComputer> {
        let attribute = Attribute<LayoutComputer>(subgraph, isEqual: LayoutComputer.equivalence, rule: make)
        attribute.setLabel("layout \(path)")
        return attribute
    }
}
