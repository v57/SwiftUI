import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Scroll targets & ScrollViewReader

struct ScrollRequest: Equatable {
    var id: Int
    var offset: CGPoint?
}

/// Views a scroll view can scroll to (`.id` views, list elements, lazy stack rows).
@MainActor
final class ScrollTargets {
    let axes: Axis.Set
    /// Scrolls so that a content-space rect is visible (anchor: where it ends up in the viewport).
    var scroll: ((CGRect, UnitPoint?) -> Void)?
    private var frames: [AnyHashable: () -> CGRect?] = [:]
    private var resolvers: [ObjectIdentifier: (AnyHashable) -> CGRect?] = [:]

    init(axes: Axis.Set) { self.axes = axes }

    func register(_ id: AnyHashable, frame: @escaping () -> CGRect?) { frames[id] = frame }
    func unregister(_ id: AnyHashable) { frames[id] = nil }
    private var enumerators: [ObjectIdentifier: () -> [AnyHashable]] = [:]
    func addResolver(_ owner: AnyObject, enumerate: @escaping () -> [AnyHashable] = { [] }, _ resolve: @escaping (AnyHashable) -> CGRect?) {
        resolvers[ObjectIdentifier(owner)] = resolve
        enumerators[ObjectIdentifier(owner)] = enumerate
    }
    func removeResolver(_ owner: AnyObject) {
        resolvers[ObjectIdentifier(owner)] = nil
        enumerators[ObjectIdentifier(owner)] = nil
    }

    /// Identifiers of all registered targets (explicit ids of scroll content, including lazy rows).
    var allIDs: [AnyHashable] { Array(frames.keys) + enumerators.values.flatMap { $0() } }

    func frame(for id: AnyHashable) -> CGRect? {
        if let frame = frames[id]?() { return frame }
        for resolve in resolvers.values {
            if let frame = resolve(id) { return frame }
        }
        return nil
    }
}

@MainActor
final class ScrollProxyBox {
    weak var targets: ScrollTargets?
}

struct ScrollProxyBoxKey: EnvironmentKey { static let defaultValue: ScrollProxyBox? = nil }
struct ScrollDisabledKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var scrollProxyBox: ScrollProxyBox? {
        get { self[ScrollProxyBoxKey.self] }
        set { self[ScrollProxyBoxKey.self] = newValue }
    }

    public var scrollDisabled: Bool {
        get { self[ScrollDisabledKey.self] }
        set { self[ScrollDisabledKey.self] = newValue }
    }
}

public struct ScrollViewProxy {
    let box: ScrollProxyBox

    @MainActor
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {
        guard let targets = box.targets, let frame = targets.frame(for: AnyHashable(id)) else { return }
        targets.scroll?(frame, anchor)
    }
}

public struct ScrollViewReader<Content: View>: View {
    let content: (ScrollViewProxy) -> Content
    @State private var box = ScrollProxyBox()

    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        self.content = content
    }

    public var body: some View {
        // The content is laid out as one unit (an implicit stack), not flattened into the parent.
        VStack { content(ScrollViewProxy(box: box)) }
            .environment(\.scrollProxyBox, box)
    }
}

public enum ScrollIndicatorVisibility: Sendable { case automatic, visible, hidden, never }

extension View {
    public func scrollDisabled(_ disabled: Bool) -> some View { environment(\.scrollDisabled, disabled) }
    public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View { self }
}

extension ViewListID {
    /// The innermost explicit identity (ForEach id or `.id`), used as a scroll target id.
    var lastExplicit: AnyHashable? {
        for component in components.reversed() {
            if case .explicit(let id) = component { return id }
        }
        return nil
    }
}

// MARK: - Lazy stacks

/// Sums of a sequence with point updates, both O(log n) (a Fenwick tree).
struct PrefixSums {
    private var tree: [CGFloat]

    init(_ values: [CGFloat]) {
        tree = [0] + values
        for index in 1..<max(tree.count, 1) {
            let parent = index + (index & -index)
            if parent < tree.count { tree[parent] += tree[index] }
        }
    }

    var count: Int { tree.count - 1 }

    /// Adds `delta` to the value at `index`.
    mutating func add(_ delta: CGFloat, at index: Int) {
        var position = index + 1
        while position < tree.count {
            tree[position] += delta
            position += position & -position
        }
    }

    /// The sum of the first `count` values.
    func prefix(_ count: Int) -> CGFloat {
        var position = min(count, tree.count - 1)
        var sum: CGFloat = 0
        while position > 0 {
            sum += tree[position]
            position -= position & -position
        }
        return sum
    }
}

/// Sizes measured so far and estimates for the rest; shared by a lazy stack's layout computers.
/// Offsets come from prefix sums of the measured sizes (and gaps) plus the estimate for the
/// unmeasured ones, so placing what shows, the stack's length and the visible range cost
/// O(log n), whatever the number of rows.
@MainActor
final class LazyStackState {
    let axis: Axis
    /// Explicit spacing; nil uses the views' own spacing (measured between built neighbours).
    let fixedSpacing: CGFloat?
    private(set) var ids: [ViewListID] = []
    private(set) var index: [ViewListID: Int] = [:]
    /// Measured sizes by identity (kept for rows that leave the list or scroll away).
    private(set) var sizes: [ViewListID: CGFloat] = [:]
    /// Spacing before an element (from its previous neighbour), once both were built.
    private(set) var gaps: [ViewListID: CGFloat] = [:]
    /// Running totals over `sizes` and `gaps` (the estimates are their averages).
    private var sizeTotal: CGFloat = 0
    private var gapTotal: CGFloat = 0
    /// Per position: measured sizes and how many are measured, measured gaps and their count.
    private var sizeSums = PrefixSums([])
    private var sizeCounts = PrefixSums([])
    private var gapSums = PrefixSums([])
    private var gapCounts = PrefixSums([])
    /// Explicit ids (`ForEach` ids, `.id`) to positions, for scroll targets (built on demand).
    private var explicitIndex: [AnyHashable: Int]?
    unowned let tracer: UpdateTracer

    init(axis: Axis, spacing: CGFloat?, tracer: UpdateTracer) {
        self.axis = axis
        self.fixedSpacing = spacing
        self.tracer = tracer
    }

    private weak var flatList: FlatViewList?

    /// The list changed: positions are rebuilt (O(n), once per list change).
    func setList(_ flat: FlatViewList) {
        guard flat !== flatList else { return }
        flatList = flat
        let newIDs = flat.ids
        guard newIDs != ids else { return }
        ids = newIDs
        index = Dictionary(newIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        explicitIndex = nil
        var sizeValues = [CGFloat](repeating: 0, count: newIDs.count)
        var sizeKnown = [CGFloat](repeating: 0, count: newIDs.count)
        var gapValues = [CGFloat](repeating: 0, count: newIDs.count)
        var gapKnown = [CGFloat](repeating: 0, count: newIDs.count)
        for (position, id) in newIDs.enumerated() {
            if let size = sizes[id] { sizeValues[position] = size; sizeKnown[position] = 1 }
            if position == 0 { gapKnown[position] = 1 } else if let gap = gaps[id] { gapValues[position] = gap; gapKnown[position] = 1 }
        }
        sizeSums = PrefixSums(sizeValues)
        sizeCounts = PrefixSums(sizeKnown)
        gapSums = PrefixSums(gapValues)
        gapCounts = PrefixSums(gapKnown)
    }

    func setSize(_ size: CGFloat, for id: ViewListID) {
        let old = sizes[id]
        guard old != size else { return }
        sizes[id] = size
        sizeTotal += size - (old ?? 0)
        guard let position = index[id] else { return }
        sizeSums.add(size - (old ?? 0), at: position)
        if old == nil { sizeCounts.add(1, at: position) }
    }

    func setGap(_ gap: CGFloat, before id: ViewListID) {
        let old = gaps[id]
        guard old != gap else { return }
        gaps[id] = gap
        gapTotal += gap - (old ?? 0)
        guard let position = index[id], position > 0 else { return }
        gapSums.add(gap - (old ?? 0), at: position)
        if old == nil { gapCounts.add(1, at: position) }
    }

    private var estimatedGap: CGFloat {
        guard !gaps.isEmpty else { return 8 }
        return gapTotal / CGFloat(gaps.count)
    }

    var estimate: CGFloat {
        guard !sizes.isEmpty else { return 28 }
        return sizeTotal / CGFloat(sizes.count)
    }

    func size(at position: Int) -> CGFloat { sizes[ids[position]] ?? estimate }

    /// Leading offset of an element along the axis.
    func offset(at position: Int) -> CGFloat {
        let sizesBefore = sizeSums.prefix(position) + (CGFloat(position) - sizeCounts.prefix(position)) * estimate
        let gapsThrough: CGFloat
        if let fixedSpacing {
            gapsThrough = CGFloat(position) * fixedSpacing
        } else {
            gapsThrough = gapSums.prefix(position + 1) + (CGFloat(position + 1) - gapCounts.prefix(position + 1)) * estimatedGap
        }
        return sizesBefore + gapsThrough
    }

    var totalLength: CGFloat {
        guard !ids.isEmpty else { return 0 }
        return offset(at: ids.count - 1) + size(at: ids.count - 1)
    }

    /// Indices intersecting `range` (stack-local coordinates along the axis).
    func visibleIndices(in range: ClosedRange<CGFloat>) -> [Int] {
        guard !ids.isEmpty else { return [] }
        // The first element ending past the range's start (ends grow with the index).
        var low = 0, high = ids.count
        while low < high {
            let middle = (low + high) / 2
            tracer.counters.listElementVisits += 1
            if offset(at: middle) + size(at: middle) > range.lowerBound { high = middle } else { low = middle + 1 }
        }
        var result: [Int] = []
        var position = low
        while position < ids.count {
            tracer.counters.listElementVisits += 1
            let start = offset(at: position)
            if start >= range.upperBound { break }
            if start + size(at: position) > range.lowerBound {
                result.append(position)
                // Nothing measured yet: build one row first so the estimate is real before filling
                // the viewport (avoids building rows that turn out to be off-screen).
                if sizes.isEmpty { break }
            }
            position += 1
        }
        return result
    }

    /// Position of an explicit id (scroll targets).
    func position(ofExplicit id: AnyHashable) -> Int? {
        if explicitIndex == nil {
            var map: [AnyHashable: Int] = [:]
            for (position, element) in ids.enumerated() {
                if let explicit = element.lastExplicit, map[explicit] == nil { map[explicit] = position }
            }
            explicitIndex = map
        }
        return explicitIndex?[id]
    }
}

final class LazyStackComputer: LayoutComputer {
    let state: LazyStackState
    let children: [(index: Int, id: ViewListID, computer: LayoutComputer)]
    let crossGuide: (AlignmentKey, any AlignmentID.Type)

    init(state: LazyStackState, children: [(index: Int, id: ViewListID, computer: LayoutComputer)], crossGuide: (AlignmentKey, any AlignmentID.Type), path: ViewPath, tracer: UpdateTracer) {
        self.state = state
        self.children = children
        self.crossGuide = crossGuide
        super.init(path: path, tracer: tracer)
    }

    private func measure(cross: CGFloat?) -> [CGSize] {
        let axis = state.axis
        let sizes = children.map { child in
            let size = child.computer.sizeThatFits(ProposedViewSize(main: nil, cross: cross, axis: axis))
            state.setSize(size[axis], for: child.id)
            return size
        }
        if state.fixedSpacing == nil {
            for (previous, child) in zip(children, children.dropFirst()) where child.index == previous.index + 1 {
                state.setGap(previous.computer.spacing.distance(to: child.computer.spacing, along: axis), before: child.id)
            }
        }
        return sizes
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let axis = state.axis
        let sizes = measure(cross: proposal[axis.other])
        // Lazy stacks take the proposed cross-axis size (unlike eager stacks).
        let fitted = sizes.reduce(CGFloat(0)) { max($0, $1[axis.other]) }
        let cross = proposal[axis.other].flatMap { $0.isFinite ? $0 : nil } ?? fitted
        return CGSize(main: state.totalLength, cross: cross, axis: axis)
    }

    func place(in geometry: ViewGeometry) -> Placements {
        let axis = state.axis
        let sizes = measure(cross: geometry.size[axis.other])
        let alignments = children.indices.map { children[$0].computer.dimensions(size: sizes[$0])[crossGuide.0, crossGuide.1] }
        let containerLine = geometry.size[axis.other] * (crossGuide.1 == HCenterAlignment.self || crossGuide.1 == VCenterAlignment.self ? 0.5 : crossGuide.1 == TrailingAlignment.self || crossGuide.1 == BottomAlignment.self ? 1 : 0)
        var geometries: [ViewGeometry] = []
        geometries.reserveCapacity(children.count)
        for (position, child) in children.enumerated() {
            let size = sizes[position]
            var origin = geometry.origin
            origin[axis] += state.offset(at: child.index)
            origin[axis.other] += containerLine - alignments[position]
            geometries.append(ViewGeometry(origin: origin, size: size, proposal: ProposedViewSize(main: nil, cross: geometry.size[axis.other], axis: axis)))
        }
        return Placements(geometries: geometries, hidden: Array(repeating: false, count: geometries.count))
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? LazyStackComputer, other.state === state, other.children.count == children.count else { return false }
        for (a, b) in zip(other.children, children) where a.computer !== b.computer || a.index != b.index { return false }
        return true
    }
}

extension _ViewInputs {
    /// Lazy stack: inside a scroll view only elements near the viewport are instantiated.
    func makeLazyStack(axis: Axis, crossGuide: (AlignmentKey, any AlignmentID.Type), spacing: CGFloat?, list: ViewList, eagerLayout: Attribute<some Layout>) -> _ViewOutputs {
        guard let viewport = scrollViewport else {
            return makeLayoutContainer(layout: eagerLayout, list: list)
        }
        let state = LazyStackState(axis: axis, spacing: spacing, tracer: tracer)
        let geometry = self.geometry
        let host = self.host
        func range(_ viewport: CGRect) -> ClosedRange<CGFloat> {
            let origin = geometry.peekValue?.origin ?? .zero
            // Exactly the visible area, like SwiftUI.
            let start = viewport.origin[axis] - origin[axis]
            return start...(start + viewport.size[axis])
        }
        let container = ViewListContainer(list: list, inputs: self, childAxis: axis) { flat in
            state.setList(flat)
            // Peek (no dependency): the viewport's size depends on this stack's layout. Viewport
            // changes re-run this filter through the observer below.
            // Until the viewport is known (first pass) nothing is built; the viewport observer
            // re-runs this once layout established it, within the same update.
            guard let current = viewport.peekValue else { return [] }
            return state.visibleIndices(in: range(current)).map { flat[$0] }
        }
        let items = container.items!
        let viewportObserver = Attribute<CGRect>(subgraph, isEqual: { $0 == $1 }) { viewport.value }
        viewportObserver.order = depth
        viewportObserver.onChange = { _ in items.invalidate() }
        viewportObserver.isEager = true
        let path = self.path
        let tracer = self.tracer
        let computer = Attribute<LayoutComputer>(subgraph, isEqual: LayoutComputer.equivalence) {
            let children = items.value.map { item in (index: state.index[item.id] ?? 0, id: item.id, computer: item.outputs.layout.value) }
            return LazyStackComputer(state: state, children: children, crossGuide: crossGuide, path: path, tracer: tracer)
        }
        let placements = Attribute<Placements>(subgraph, isEqual: { $0 == $1 }) {
            let engine = computer.value as! LazyStackComputer
            tracer.record(.placement, path)
            let result = engine.place(in: geometry.value)
            // Measured sizes may change which rows should be visible: re-filter after this pass.
            let wanted = state.visibleIndices(in: range(viewport.peekValue ?? .zero))
            if wanted.count != engine.children.count || zip(wanted, engine.children).contains(where: { $0 != $1.index }) {
                host.enqueueAfterUpdate { items.invalidate() }
            }
            return result
        }
        container.placement = { index in
            let all = placements.value.geometries
            return index < all.count ? all[index] : .zero
        }
        if let targets = scrollTargets {
            let spaceOrigin = self.spaceOrigin
            targets.addResolver(state, enumerate: { state.ids.compactMap(\.lastExplicit) }) { id in
                guard let index = state.position(ofExplicit: id) else { return nil }
                let space = spaceOrigin?.peekValue ?? .zero
                let local = geometry.peekValue?.origin ?? .zero
                let origin = CGPoint(x: local.x + space.x, y: local.y + space.y)
                var frame = CGRect(origin: origin, size: geometry.peekValue?.size ?? .zero)
                frame.origin[axis] += state.offset(at: index)
                if axis == .vertical { frame.size.height = state.size(at: index) } else { frame.size.width = state.size(at: index) }
                return frame
            }
            subgraph.onDestroy { [weak targets] in targets?.removeResolver(state) }
        }
        var preferences = PreferenceOutputs()
        for key in preferenceKeys {
            preferences.values[key.id] = key.combine(dynamic: {
                items.value.compactMap { $0.outputs.preferences.values[key.id] }
            }, subgraph: subgraph)
        }
        return _ViewOutputs(layout: computer, preferences: preferences)
    }
}

public struct LazyVStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "LazyVStack")
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs)
        let (alignment, spacing) = AnyAttribute.withoutDependencies { (view.attribute.value.alignment, view.attribute.value.spacing) }
        let layout = view.project(inputs) { _LazyEagerStackLayout(base: _VStackLayout(alignment: $0.alignment, spacing: $0.spacing), axis: .vertical) }
        return inputs.makeLazyStack(axis: .vertical, crossGuide: (alignment.key, alignment.id), spacing: spacing, list: list.list, eagerLayout: layout.attribute)
    }
}

public struct LazyHStack<Content: View>: View {
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "LazyHStack")
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: inputs.listInputs)
        let (alignment, spacing) = AnyAttribute.withoutDependencies { (view.attribute.value.alignment, view.attribute.value.spacing) }
        let layout = view.project(inputs) { _LazyEagerStackLayout(base: _HStackLayout(alignment: $0.alignment, spacing: $0.spacing), axis: .horizontal) }
        return inputs.makeLazyStack(axis: .horizontal, crossGuide: (alignment.key, alignment.id), spacing: spacing, list: list.list, eagerLayout: layout.attribute)
    }
}

// MARK: - Scroll geometry

/// Mirrors `SwiftUI.ScrollGeometry`.
public struct ScrollGeometry: Equatable, Sendable {
    public var contentOffset: CGPoint
    public var contentSize: CGSize
    public var contentInsets: EdgeInsets
    public var containerSize: CGSize
    public var visibleRect: CGRect { CGRect(origin: contentOffset, size: containerSize) }
    public var bounds: CGRect { CGRect(origin: contentOffset, size: containerSize) }
}

/// One `onScrollGeometryChange` registration (called after updates when its value changes).
@MainActor
final class ScrollGeometryObserver {
    let update: @MainActor (ScrollGeometry) -> Void
    init(update: @escaping @MainActor (ScrollGeometry) -> Void) { self.update = update }
}

struct ScrollGeometryObserversKey: EnvironmentKey { static let defaultValue: [ScrollGeometryObserver] = [] }

extension EnvironmentValues {
    var scrollGeometryObservers: [ScrollGeometryObserver] {
        get { self[ScrollGeometryObserversKey.self] }
        set { self[ScrollGeometryObserversKey.self] = newValue }
    }
}

extension ScrollGeometryObserver: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: ScrollGeometryObserver, _ rhs: ScrollGeometryObserver) -> Bool { lhs === rhs }
}

struct _ScrollGeometryChangeModifier<T: Equatable>: ViewModifier {
    let transform: (ScrollGeometry) -> T
    let action: @MainActor (T, T) -> Void
    @State private var box = Box()

    @MainActor final class Box {
        var last: T?
        var transform: ((ScrollGeometry) -> T)?
        var action: (@MainActor (T, T) -> Void)?
        lazy var observer = ScrollGeometryObserver { [unowned self] geometry in
            guard let transform else { return }
            let value = transform(geometry)
            let old = last
            last = value
            if let old, old != value { action?(old, value) } else if old == nil { action?(value, value) }
        }
    }

    func body(content: Content) -> some View {
        box.transform = transform
        box.action = action
        let observer = box.observer
        return content.transformEnvironment(\.scrollGeometryObservers) { $0.append(observer) }
    }
}

extension View {
    public func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T, action: @escaping @MainActor (_ oldValue: T, _ newValue: T) -> Void) -> some View {
        modifier(_ScrollGeometryChangeModifier(transform: transform, action: action))
    }

}

public enum ScrollPhase: Sendable { case idle, tracking, interacting, decelerating, animating }

public enum ScrollDismissesKeyboardMode: Sendable { case automatic, immediately, interactively, never }

/// A lazy stack outside a scroll view (laid out eagerly). Like SwiftUI's, it takes the proposed
/// cross-axis size and has standard spacing around it (it is a container, not its children).
struct _LazyEagerStackLayout<Base: Layout>: Layout where Base.Cache == Void {
    let base: Base
    let axis: Axis

    func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing { .default }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        var size = base.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
        if let cross = proposal[axis.other], cross.isFinite { size[axis.other] = cross }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        base.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}
