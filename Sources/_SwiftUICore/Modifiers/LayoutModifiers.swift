import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Helper for primitive layout modifiers built on `UnaryLayoutComputer`.
@MainActor
protocol UnaryLayoutModifier: ViewModifier where Body == Never {
    static var pathComponent: String { get }
    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer
}

extension UnaryLayoutModifier {
    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let tracer = inputs.tracer
        return inputs.makeUnaryLayout(component: pathComponent, body: body) { child, path in
            modifier.attribute.value.makeComputer(child: child, path: path, tracer: tracer)
        }
    }
}

// MARK: - Control spacing

/// Composite controls (a stepper with its label, ...) space like one platform control rather
/// than like the text inside them.
struct _ControlSpacingLayout: UnaryLayoutModifier, Equatable {
    static var pathComponent: String { "controlSpacing" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        ControlSpacingComputer(child: child, path: path, tracer: tracer)
    }
}

final class ControlSpacingComputer: UnaryLayoutComputer {
    override var computedSpacing: ViewSpacing { .default }
    override func hasSameParameters(as other: LayoutComputer) -> Bool { other is ControlSpacingComputer }
}

// MARK: - Padding

public struct _PaddingLayout: UnaryLayoutModifier, Equatable {
    public var edges: Edge.Set
    public var insets: EdgeInsets?
    static var pathComponent: String { "padding" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        PaddingComputer(insets: insets ?? EdgeInsets(edges, 16), child: child, path: path, tracer: tracer)
    }
}

final class PaddingComputer: UnaryLayoutComputer {
    let insets: EdgeInsets

    init(insets: EdgeInsets, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.insets = insets
        super.init(child: child, path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        var inner = proposal
        if let width = inner.width { inner.width = max(0, width - insets.horizontal) }
        if let height = inner.height { inner.height = max(0, height - insets.vertical) }
        let size = child.sizeThatFits(inner)
        return CGSize(width: size.width + insets.horizontal, height: size.height + insets.vertical)
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        let inner = CGSize(width: max(0, size.width - insets.horizontal), height: max(0, size.height - insets.vertical))
        return child.explicitAlignment(key, in: inner).map { $0 + (key.axis == .horizontal ? insets.leading : insets.top) }
    }

    /// Padded edges prefer the default spacing; unpadded ones keep the child's (measured:
    /// `.padding(.horizontal, 5)` or zero padding leave text spacing above and below intact).
    override var computedSpacing: ViewSpacing {
        var spacing = child.spacing
        let padded = ViewSpacing.default
        if insets.top != 0 { spacing.topEdge = padded.topEdge }
        if insets.bottom != 0 { spacing.bottomEdge = padded.bottomEdge }
        if insets.leading != 0 { spacing.leadingEdge = padded.leadingEdge }
        if insets.trailing != 0 { spacing.trailingEdge = padded.trailingEdge }
        if insets != EdgeInsets() { spacing.isSpacer = false }
        return spacing
    }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let size = CGSize(width: max(0, geometry.size.width - insets.horizontal), height: max(0, geometry.size.height - insets.vertical))
        return ViewGeometry(
            origin: CGPoint(x: geometry.origin.x + insets.leading, y: geometry.origin.y + insets.top),
            size: size,
            proposal: ProposedViewSize(size)
        )
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        (other as? PaddingComputer)?.insets == insets
    }
}

extension View {
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        modifier(_PaddingLayout(edges: edges, insets: length.map { EdgeInsets(edges, $0) }))
    }

    public func padding(_ length: CGFloat) -> some View {
        modifier(_PaddingLayout(edges: .all, insets: EdgeInsets(.all, length)))
    }

    public func padding(_ insets: EdgeInsets) -> some View {
        modifier(_PaddingLayout(edges: .all, insets: insets))
    }
}

// MARK: - Fixed frame

public struct _FrameLayout: UnaryLayoutModifier, Equatable {
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment
    static var pathComponent: String { "frame" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        FrameComputer(width: width, height: height, alignment: alignment, child: child, path: path, tracer: tracer)
    }
}

final class FrameComputer: UnaryLayoutComputer {
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment

    init(width: CGFloat?, height: CGFloat?, alignment: Alignment, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.width = width
        self.height = height
        self.alignment = alignment
        super.init(child: child, path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        if let width, let height { return CGSize(width: width, height: height) }
        let childSize = child.sizeThatFits(ProposedViewSize(width: width ?? proposal.width, height: height ?? proposal.height))
        return CGSize(width: width ?? childSize.width, height: height ?? childSize.height)
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? { nil }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        // Unfixed axes pass the frame's own proposal through (as when sizing).
        let proposal = ProposedViewSize(width: width ?? geometry.proposal.width, height: height ?? geometry.proposal.height)
        let childSize = child.sizeThatFits(proposal)
        return geometry.aligning(childSize: childSize, child: child, container: dimensions(size: geometry.size), alignment: alignment, proposal: proposal)
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        guard let other = other as? FrameComputer else { return false }
        return other.width == width && other.height == height && other.alignment == alignment
    }

    /// Layout boundary: with both dimensions fixed, the child's size cannot affect the parent.
    override func isEquivalent(to other: LayoutComputer) -> Bool {
        if width != nil, height != nil, hasSameParameters(as: other) { return true }
        return super.isEquivalent(to: other)
    }
}

// MARK: - Flexible frame

public struct _FlexFrameLayout: UnaryLayoutModifier, Equatable {
    let minWidth, idealWidth, maxWidth: CGFloat?
    let minHeight, idealHeight, maxHeight: CGFloat?
    let alignment: Alignment
    static var pathComponent: String { "frame" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        FlexFrameComputer(layout: self, child: child, path: path, tracer: tracer)
    }
}

final class FlexFrameComputer: UnaryLayoutComputer {
    let layout: _FlexFrameLayout

    init(layout: _FlexFrameLayout, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.layout = layout
        super.init(child: child, path: path, tracer: tracer)
    }

    private static func clampProposal(_ value: CGFloat?, min: CGFloat?, ideal: CGFloat?, max: CGFloat?) -> CGFloat? {
        guard var value else { return ideal }
        if let min { value = Swift.max(value, min) }
        if let max { value = Swift.min(value, max) }
        return value
    }

    private static func resolve(_ proposed: CGFloat?, child: CGFloat, min: CGFloat?, ideal: CGFloat?, max: CGFloat?) -> CGFloat {
        guard min != nil || max != nil else { return child }
        let candidate = proposed ?? ideal ?? child
        let lower = min ?? child
        let upper = Swift.max(max ?? child, lower)
        return Swift.min(Swift.max(candidate, lower), upper)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let l = layout
        let childProposal = ProposedViewSize(
            width: Self.clampProposal(proposal.width, min: l.minWidth, ideal: l.idealWidth, max: l.maxWidth),
            height: Self.clampProposal(proposal.height, min: l.minHeight, ideal: l.idealHeight, max: l.maxHeight)
        )
        let childSize = child.sizeThatFits(childProposal)
        return CGSize(
            width: Self.resolve(proposal.width, child: childSize.width, min: l.minWidth, ideal: l.idealWidth, max: l.maxWidth),
            height: Self.resolve(proposal.height, child: childSize.height, min: l.minHeight, ideal: l.idealHeight, max: l.maxHeight)
        )
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? { nil }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let l = layout
        let proposal = ProposedViewSize(
            width: Self.clampProposal(geometry.size.width, min: l.minWidth, ideal: l.idealWidth, max: l.maxWidth),
            height: Self.clampProposal(geometry.size.height, min: l.minHeight, ideal: l.idealHeight, max: l.maxHeight)
        )
        let childSize = child.sizeThatFits(proposal)
        return geometry.aligning(childSize: childSize, child: child, container: dimensions(size: geometry.size), alignment: l.alignment, proposal: proposal)
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        (other as? FlexFrameComputer)?.layout == layout
    }
}

extension View {
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(_FrameLayout(width: width, height: height, alignment: alignment))
    }

    public func frame(
        minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        modifier(_FlexFrameLayout(
            minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth,
            minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight,
            alignment: alignment
        ))
    }
}

// MARK: - fixedSize / layoutPriority / layoutValue

public struct _FixedSizeLayout: UnaryLayoutModifier, Equatable {
    let horizontal: Bool
    let vertical: Bool
    static var pathComponent: String { "fixedSize" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        FixedSizeComputer(horizontal: horizontal, vertical: vertical, child: child, path: path, tracer: tracer)
    }
}

final class FixedSizeComputer: UnaryLayoutComputer {
    let horizontal: Bool
    let vertical: Bool

    init(horizontal: Bool, vertical: Bool, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.horizontal = horizontal
        self.vertical = vertical
        super.init(child: child, path: path, tracer: tracer)
    }

    private func adjust(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: horizontal ? nil : proposal.width, height: vertical ? nil : proposal.height)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { child.sizeThatFits(adjust(proposal)) }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let proposal = adjust(geometry.proposal)
        let size = child.sizeThatFits(proposal)
        return geometry.aligning(childSize: size, child: child, container: dimensions(size: geometry.size), alignment: .center, proposal: proposal)
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        guard let other = other as? FixedSizeComputer else { return false }
        return other.horizontal == horizontal && other.vertical == vertical
    }
}

public struct _LayoutPriorityLayout: UnaryLayoutModifier, Equatable {
    let priority: Double
    static var pathComponent: String { "layoutPriority" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        PriorityComputer(priority: priority, child: child, path: path, tracer: tracer)
    }
}

final class PriorityComputer: UnaryLayoutComputer {
    let priority: Double
    init(priority: Double, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.priority = priority
        super.init(child: child, path: path, tracer: tracer)
    }
    override var layoutPriority: Double { priority }
    override func hasSameParameters(as other: LayoutComputer) -> Bool { (other as? PriorityComputer)?.priority == priority }
}

struct _LayoutValueModifier<K: LayoutValueKey>: UnaryLayoutModifier {
    let value: K.Value
    static var pathComponent: String { "layoutValue" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        LayoutValueComputer<K>(value: value, child: child, path: path, tracer: tracer)
    }
}

final class LayoutValueComputer<K: LayoutValueKey>: UnaryLayoutComputer {
    let value: K.Value
    init(value: K.Value, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.value = value
        super.init(child: child, path: path, tracer: tracer)
    }
    override func layoutValue(_ key: ObjectIdentifier) -> Any? {
        key == ObjectIdentifier(K.self) ? value : child.layoutValue(key)
    }
    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        guard let other = other as? LayoutValueComputer<K> else { return false }
        return GraphComparison.isIdentical(other.value, value)
    }
}

extension View {
    public func fixedSize() -> some View { modifier(_FixedSizeLayout(horizontal: true, vertical: true)) }

    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View {
        modifier(_FixedSizeLayout(horizontal: horizontal, vertical: vertical))
    }

    public func layoutPriority(_ value: Double) -> some View { modifier(_LayoutPriorityLayout(priority: value)) }

    public func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> some View {
        modifier(_LayoutValueModifier<K>(value: value))
    }
}

// MARK: - Offset / position

public struct _OffsetEffect: UnaryLayoutModifier, Equatable {
    let offset: CGSize
    static var pathComponent: String { "offset" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        OffsetComputer(offset: offset, child: child, path: path, tracer: tracer)
    }
}

/// Offset never affects layout: the computer is equivalent to its child's for the parent.
final class OffsetComputer: UnaryLayoutComputer {
    let offset: CGSize
    init(offset: CGSize, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.offset = offset
        super.init(child: child, path: path, tracer: tracer)
    }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        var result = geometry
        result.origin.x += offset.width
        result.origin.y += offset.height
        return result
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool { (other as? OffsetComputer)?.offset == offset }

    /// The offset does not change the size: only the child matters to the parent.
    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? OffsetComputer else { return false }
        return other.child === child
    }
}

public struct _PositionLayout: UnaryLayoutModifier, Equatable {
    let position: CGPoint
    static var pathComponent: String { "position" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        PositionComputer(position: position, child: child, path: path, tracer: tracer)
    }
}

final class PositionComputer: UnaryLayoutComputer {
    let position: CGPoint
    init(position: CGPoint, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.position = position
        super.init(child: child, path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { proposal.replacingUnspecifiedDimensions() }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let size = child.sizeThatFits(.unspecified)
        return ViewGeometry(
            origin: CGPoint(x: geometry.origin.x + position.x - size.width / 2, y: geometry.origin.y + position.y - size.height / 2),
            size: size,
            proposal: .unspecified
        )
    }

    /// Takes all proposed space regardless of the child: a layout boundary.
    override func isEquivalent(to other: LayoutComputer) -> Bool { other is PositionComputer }

    override func hasSameParameters(as other: LayoutComputer) -> Bool { (other as? PositionComputer)?.position == position }
}

extension View {
    public func offset(_ offset: CGSize) -> some View { modifier(_OffsetEffect(offset: offset)) }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { modifier(_OffsetEffect(offset: CGSize(width: x, height: y))) }
    public func position(_ position: CGPoint) -> some View { modifier(_PositionLayout(position: position)) }
    public func position(x: CGFloat = 0, y: CGFloat = 0) -> some View { modifier(_PositionLayout(position: CGPoint(x: x, y: y))) }
}

// MARK: - Aspect ratio

public struct _AspectRatioLayout: UnaryLayoutModifier, Equatable {
    let aspectRatio: CGFloat?
    let contentMode: ContentMode
    static var pathComponent: String { "aspectRatio" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        AspectRatioComputer(ratio: aspectRatio, contentMode: contentMode, child: child, path: path, tracer: tracer)
    }
}

final class AspectRatioComputer: UnaryLayoutComputer {
    let ratio: CGFloat?
    let contentMode: ContentMode

    init(ratio: CGFloat?, contentMode: ContentMode, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.ratio = ratio
        self.contentMode = contentMode
        super.init(child: child, path: path, tracer: tracer)
    }

    /// SwiftUI: an unspecified proposal passes through; otherwise a missing dimension counts as
    /// unbounded when fitting and as zero when filling.
    private func targetProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        if proposal.width == nil && proposal.height == nil { return .unspecified }
        let ratio: CGFloat
        if let fixed = self.ratio {
            ratio = fixed
        } else {
            let ideal = child.sizeThatFits(.unspecified)
            ratio = ideal.height > 0 ? ideal.width / ideal.height : 1
        }
        let missing: CGFloat = contentMode == .fit ? .infinity : 0
        let available = CGSize(width: proposal.width ?? missing, height: proposal.height ?? missing)
        let widthFromHeight = available.height * ratio
        let byWidth = contentMode == .fit ? widthFromHeight > available.width : widthFromHeight < available.width
        return byWidth
            ? ProposedViewSize(width: available.width, height: available.width / ratio)
            : ProposedViewSize(width: widthFromHeight, height: available.height)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        child.sizeThatFits(targetProposal(proposal))
    }

    override func placeChild(in geometry: ViewGeometry, child: LayoutComputer) -> ViewGeometry {
        let target = targetProposal(geometry.proposal)
        let size = child.sizeThatFits(target)
        return geometry.aligning(childSize: size, child: child, container: dimensions(size: geometry.size), alignment: .center, proposal: target)
    }

    override func hasSameParameters(as other: LayoutComputer) -> Bool {
        guard let other = other as? AspectRatioComputer else { return false }
        return other.ratio == ratio && other.contentMode == contentMode
    }
}

extension View {
    public func aspectRatio(_ aspectRatio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        modifier(_AspectRatioLayout(aspectRatio: aspectRatio, contentMode: contentMode))
    }

    public func aspectRatio(_ aspectRatio: CGSize, contentMode: ContentMode) -> some View {
        modifier(_AspectRatioLayout(aspectRatio: aspectRatio.width / aspectRatio.height, contentMode: contentMode))
    }

    public func scaledToFit() -> some View { aspectRatio(contentMode: .fit) }
    public func scaledToFill() -> some View { aspectRatio(contentMode: .fill) }
}

// MARK: - Alignment guides

public struct _AlignmentGuideModifier: UnaryLayoutModifier {
    let key: AlignmentKey
    let computeValue: @MainActor (ViewDimensions) -> CGFloat
    static var pathComponent: String { "alignmentGuide" }

    func makeComputer(child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) -> UnaryLayoutComputer {
        AlignmentGuideComputer(key: key, compute: computeValue, child: child, path: path, tracer: tracer)
    }
}

final class AlignmentGuideComputer: UnaryLayoutComputer {
    let key: AlignmentKey
    let compute: @MainActor (ViewDimensions) -> CGFloat

    init(key: AlignmentKey, compute: @escaping @MainActor (ViewDimensions) -> CGFloat, child: LayoutComputer, path: ViewPath, tracer: UpdateTracer) {
        self.key = key
        self.compute = compute
        super.init(child: child, path: path, tracer: tracer)
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        if key == self.key { return compute(child.dimensions(size: size)) }
        return child.explicitAlignment(key, in: size)
    }
}

extension View {
    public func alignmentGuide(_ g: HorizontalAlignment, computeValue: @escaping @MainActor (ViewDimensions) -> CGFloat) -> some View {
        modifier(_AlignmentGuideModifier(key: g.key, computeValue: computeValue))
    }

    public func alignmentGuide(_ g: VerticalAlignment, computeValue: @escaping @MainActor (ViewDimensions) -> CGFloat) -> some View {
        modifier(_AlignmentGuideModifier(key: g.key, computeValue: computeValue))
    }
}
