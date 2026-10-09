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
    func addResolver(_ owner: AnyObject, _ resolve: @escaping (AnyHashable) -> CGRect?) { resolvers[ObjectIdentifier(owner)] = resolve }
    func removeResolver(_ owner: AnyObject) { resolvers[ObjectIdentifier(owner)] = nil }

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
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: Axis.Set = [.vertical, .horizontal]) -> some View { self }
    public func scrollDismissesKeyboard<M>(_ mode: M) -> some View { self }
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

/// Sizes measured so far and estimates for the rest; shared by a lazy stack's layout computers.
@MainActor
final class LazyStackState {
    let axis: Axis
    /// Explicit spacing; nil uses the views' own spacing (measured between built neighbours).
    let fixedSpacing: CGFloat?
    var ids: [ViewListID] = []
    var index: [ViewListID: Int] = [:]
    var sizes: [ViewListID: CGFloat] = [:]
    /// Spacing before an element (from its previous neighbour), once both were built.
    var gaps: [ViewListID: CGFloat] = [:]

    init(axis: Axis, spacing: CGFloat?) {
        self.axis = axis
        self.fixedSpacing = spacing
    }

    private var estimatedGap: CGFloat {
        guard !gaps.isEmpty else { return 8 }
        return gaps.values.reduce(0, +) / CGFloat(gaps.count)
    }

    /// Spacing between element `index - 1` and `index`.
    func gap(before index: Int) -> CGFloat {
        if let fixedSpacing { return fixedSpacing }
        return gaps[ids[index]] ?? estimatedGap
    }

    var estimate: CGFloat {
        guard !sizes.isEmpty else { return 28 }
        return sizes.values.reduce(0, +) / CGFloat(sizes.count)
    }

    func size(at index: Int) -> CGFloat { sizes[ids[index]] ?? estimate }

    /// Leading offset of every element along the axis.
    func offsets() -> [CGFloat] {
        var result: [CGFloat] = []
        result.reserveCapacity(ids.count)
        var position: CGFloat = 0
        let estimate = self.estimate
        for (index, id) in ids.enumerated() {
            if index > 0 { position += gap(before: index) }
            result.append(position)
            position += sizes[id] ?? estimate
        }
        return result
    }

    var totalLength: CGFloat {
        guard !ids.isEmpty else { return 0 }
        let estimate = self.estimate
        var total: CGFloat = 0
        for (index, id) in ids.enumerated() {
            if index > 0 { total += gap(before: index) }
            total += sizes[id] ?? estimate
        }
        return total
    }

    /// Indices intersecting `range` (stack-local coordinates along the axis).
    func visibleIndices(in range: ClosedRange<CGFloat>) -> [Int] {
        let offsets = offsets()
        var result: [Int] = []
        for index in ids.indices {
            let start = offsets[index]
            let end = start + size(at: index)
            if end > range.lowerBound && start < range.upperBound {
                result.append(index)
                // Nothing measured yet: build one row first so the estimate is real before filling
                // the viewport (avoids building rows that turn out to be off-screen).
                if sizes.isEmpty { break }
            }
            if start >= range.upperBound { break }
        }
        return result
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
            state.sizes[child.id] = size[axis]
            return size
        }
        if state.fixedSpacing == nil {
            for (previous, child) in zip(children, children.dropFirst()) where child.index == previous.index + 1 {
                state.gaps[child.id] = previous.computer.spacing.distance(to: child.computer.spacing, along: axis)
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
        let offsets = state.offsets()
        let alignments = children.indices.map { children[$0].computer.dimensions(size: sizes[$0])[crossGuide.0, crossGuide.1] }
        let containerLine = geometry.size[axis.other] * (crossGuide.1 == HCenterAlignment.self || crossGuide.1 == VCenterAlignment.self ? 0.5 : crossGuide.1 == TrailingAlignment.self || crossGuide.1 == BottomAlignment.self ? 1 : 0)
        var geometries: [ViewGeometry] = []
        for (position, child) in children.enumerated() {
            let size = sizes[position]
            var origin = geometry.origin
            origin[axis] += offsets[child.index]
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
        let state = LazyStackState(axis: axis, spacing: spacing)
        let geometry = self.geometry
        let host = self.host
        func range(_ viewport: CGRect) -> ClosedRange<CGFloat> {
            let origin = geometry.peekValue?.origin ?? .zero
            // Exactly the visible area, like SwiftUI.
            let start = viewport.origin[axis] - origin[axis]
            return start...(start + viewport.size[axis])
        }
        let container = ViewListContainer(list: list, inputs: self, childAxis: axis) { flat in
            state.ids = flat.map(\.0)
            state.index = Dictionary(flat.enumerated().map { ($1.0, $0) }, uniquingKeysWith: { first, _ in first })
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
            let wanted = state.visibleIndices(in: range(viewport.peekValue ?? .zero)).map { state.ids[$0] }
            if wanted != engine.children.map(\.id) {
                host.enqueueAfterUpdate { items.invalidate() }
            }
            return result
        }
        container.placement = { index in
            let all = placements.value.geometries
            return index < all.count ? all[index] : .zero
        }
        if let targets = scrollTargets {
            targets.addResolver(state) { id in
                guard let index = state.ids.firstIndex(where: { $0.lastExplicit == id }) else { return nil }
                let origin = geometry.peekValue?.origin ?? .zero
                var frame = CGRect(origin: origin, size: geometry.peekValue?.size ?? .zero)
                frame.origin[axis] += state.offsets()[index]
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
        let layout = view.project(inputs) { _VStackLayout(alignment: $0.alignment, spacing: $0.spacing) }
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
        let layout = view.project(inputs) { _HStackLayout(alignment: $0.alignment, spacing: $0.spacing) }
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

    public func onScrollPhaseChange(_ action: @escaping @MainActor (ScrollPhase, ScrollPhase) -> Void) -> some View { self }
}

public enum ScrollPhase: Sendable { case idle, tracking, interacting, decelerating, animating }
