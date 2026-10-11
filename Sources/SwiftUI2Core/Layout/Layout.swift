import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct LayoutProperties: Sendable {
    public var stackOrientation: Axis?
    public init() {}
}

/// Mirrors `SwiftUI.Layout`. Built-in stacks are implemented on top of it too.
@MainActor @preconcurrency
public protocol Layout {
    static var layoutProperties: LayoutProperties { get }
    associatedtype Cache = Void
    typealias Subviews = LayoutSubviews

    func makeCache(subviews: Subviews) -> Cache
    func updateCache(_ cache: inout Cache, subviews: Subviews)
    func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat?
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat?
}

extension Layout {
    public static var layoutProperties: LayoutProperties { LayoutProperties() }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        var result = ViewSpacing.empty
        for subview in subviews { result.formUnion(subview.spacing) }
        return subviews.isEmpty ? .zero : result
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

extension Layout where Cache == Void {
    public func makeCache(subviews: Subviews) -> Void {}
}

extension Layout {
    /// `MyLayout { content }` — uses the layout as a container view.
    public func callAsFunction<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        _LayoutRoot(layout: self, content: content())
    }
}

// MARK: - Subviews

public protocol LayoutValueKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Runs main-actor code from a nonisolated context known to be on the main thread (layout).
nonisolated func _onMainActor<T>(_ body: @MainActor () -> T) -> T {
    nonisolated(unsafe) var result: T?
    MainActor.assumeIsolated { result = body() }
    return result!
}

/// Records child placements while `placeSubviews` runs.
@MainActor
final class PlacementRecorder {
    var geometries: [ViewGeometry]
    var hidden: [Bool]
    init(count: Int) {
        geometries = Array(repeating: .zero, count: count)
        hidden = Array(repeating: false, count: count)
    }
}

/// Result of placing a container's children.
struct Placements: Equatable {
    var geometries: [ViewGeometry]
    var hidden: [Bool]
}

@MainActor
public struct LayoutSubview: Equatable {
    let computer: LayoutComputer
    let index: Int
    let recorder: PlacementRecorder?
    var traits = ViewTraits()

    init(computer: LayoutComputer, index: Int, recorder: PlacementRecorder?, traits: ViewTraits = ViewTraits()) {
        self.computer = computer
        self.index = index
        self.recorder = recorder
        self.traits = traits
    }

    /// Hides the subview (not rendered); used by layouts that show a subset (ViewThatFits).
    func hide() {
        guard let recorder else { return }
        recorder.hidden[index] = true
        recorder.geometries[index] = ViewGeometry(origin: .zero, size: .zero, proposal: .zero)
    }

    // Like SwiftUI's, usable from nonisolated `Layout` methods (layout always runs on the main thread).
    public nonisolated func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        MainActor.assumeIsolated { computer.sizeThatFits(proposal) }
    }
    public nonisolated func dimensions(in proposal: ProposedViewSize) -> ViewDimensions {
        _onMainActor { computer.dimensions(in: proposal) }
    }
    public nonisolated var priority: Double { MainActor.assumeIsolated { computer.layoutPriority } }
    public nonisolated var spacing: ViewSpacing { MainActor.assumeIsolated { computer.spacing } }

    public nonisolated subscript<K: LayoutValueKey>(key: K.Type) -> K.Value {
        _onMainActor { (computer.layoutValue(ObjectIdentifier(key)) as? K.Value) ?? K.defaultValue }
    }

    public nonisolated func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {
        MainActor.assumeIsolated {
            guard let recorder else { return }
            let size = computer.sizeThatFits(proposal)
            let origin = CGPoint(x: position.x - anchor.x * size.width, y: position.y - anchor.y * size.height)
            recorder.geometries[index] = ViewGeometry(origin: origin, size: size, proposal: proposal)
        }
    }

    var isSpacer: Bool { computer.spacing.isSpacer }

    public nonisolated static func == (lhs: LayoutSubview, rhs: LayoutSubview) -> Bool {
        lhs.computer === rhs.computer && lhs.index == rhs.index
    }
}

public struct LayoutSubviews: RandomAccessCollection, Equatable {
    let elements: [LayoutSubview]
    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(index: Int) -> LayoutSubview { elements[index] }
    public subscript(bounds: Range<Int>) -> LayoutSubviews { LayoutSubviews(elements: Array(elements[bounds])) }

    public var layoutDirection: LayoutDirection { .leftToRight }
}

// MARK: - Engine

/// Layout computer for a `Layout` with children.
@MainActor
final class LayoutEngineComputer<L: Layout>: LayoutComputer {
    let layout: L
    let children: [LayoutComputer]
    let traits: [ViewTraits]
    let cacheBox: LayoutCacheBox<L.Cache>
    let forwardsSingleChild: Bool

    init(layout: L, children: [LayoutComputer], traits: [ViewTraits], cacheBox: LayoutCacheBox<L.Cache>, path: ViewPath, tracer: UpdateTracer) {
        self.layout = layout
        self.children = children
        self.traits = traits
        self.cacheBox = cacheBox
        self.forwardsSingleChild = (layout as? _UnaryListLayout) != nil && children.count == 1
        super.init(path: path, tracer: tracer)
    }

    var subviews: LayoutSubviews {
        LayoutSubviews(elements: children.enumerated().map { LayoutSubview(computer: $1, index: $0, recorder: nil, traits: traits[$0]) })
    }

    /// The proposal of the layout's latest `sizeThatFits` call (sizes are memoized per proposal).
    private var sizedProposal: ProposedViewSize?

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        sizedProposal = proposal
        return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cacheBox.cache!)
    }

    func place(in geometry: ViewGeometry) -> Placements {
        // Layouts may keep proposal-dependent results in their cache for `placeSubviews` (e.g. a
        // grid's column count). When probes with other proposals ran after the placement proposal
        // was sized (its size then comes from the memo), size it again so the cache matches.
        if sizedProposal != geometry.proposal {
            sizedProposal = geometry.proposal
            _ = layout.sizeThatFits(proposal: geometry.proposal, subviews: subviews, cache: &cacheBox.cache!)
        }
        let recorder = PlacementRecorder(count: children.count)
        let recordingSubviews = LayoutSubviews(elements: children.enumerated().map {
            LayoutSubview(computer: $1, index: $0, recorder: recorder, traits: traits[$0])
        })
        // SwiftUI places with the proposal the view was given; stacks re-derive from bounds.
        layout.placeSubviews(in: geometry.frame, proposal: geometry.proposal, subviews: recordingSubviews, cache: &cacheBox.cache!)
        return Placements(geometries: recorder.geometries, hidden: recorder.hidden)
    }

    override func explicitAlignment(_ key: AlignmentKey, in size: CGSize) -> CGFloat? {
        if forwardsSingleChild { return children[0].explicitAlignment(key, in: size) }
        let bounds = CGRect(origin: .zero, size: size)
        let proposal = ProposedViewSize(size)
        if key.axis == .horizontal {
            let guide = HorizontalAlignment(key.id)
            return layout.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &cacheBox.cache!)
        } else {
            let guide = VerticalAlignment(key.id)
            return layout.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &cacheBox.cache!)
        }
    }

    override var spacing: ViewSpacing {
        if forwardsSingleChild { return children[0].spacing }
        return layout.spacing(subviews: subviews, cache: &cacheBox.cache!)
    }

    override var layoutPriority: Double { forwardsSingleChild ? children[0].layoutPriority : 0 }

    override func layoutValue(_ key: ObjectIdentifier) -> Any? {
        forwardsSingleChild ? children[0].layoutValue(key) : nil
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? LayoutEngineComputer<L> else { return false }
        guard other.children.count == children.count else { return false }
        for (a, b) in zip(other.children, children) where a !== b { return false }
        return GraphComparison.isIdentical(other.layout, layout)
    }
}

@MainActor
final class LayoutCacheBox<Cache> {
    var cache: Cache?
}

// MARK: - Container construction

@MainActor
extension _ViewInputs {
    /// Builds a layout container: children come from `list`, are instantiated by a
    /// `ViewListContainer`, measured by a `LayoutEngineComputer` and placed by `layout`.
    func makeLayoutContainer<L: Layout>(layout layoutAttribute: Attribute<L>, list: ViewList, component: String? = nil) -> _ViewOutputs {
        var inputs = self
        // Accessibility modifiers on a stack make it an element grouping its children.
        if let attachment = inputs.accessibility, !attachment.isConsumed {
            inputs.render = inputs.makePlatformNode(content: inputs.constant(RenderContent.effect(.group)))
        }
        if let component { inputs.path = path.appending(component) }
        let container = ViewListContainer(list: list, inputs: inputs, childAxis: L.layoutProperties.stackOrientation)
        let path = inputs.path
        let tracer = inputs.tracer
        let cacheBox = LayoutCacheBox<L.Cache>()
        let items = container.items!
        let computer = Attribute<LayoutComputer>(inputs.subgraph, isEqual: LayoutComputer.equivalence) {
            let currentItems = items.value
            let children = currentItems.map { $0.outputs.layout.value }
            let traits = currentItems.map(\.traits)
            let layout = layoutAttribute.value
            let subviews = LayoutSubviews(elements: children.enumerated().map { LayoutSubview(computer: $1, index: $0, recorder: nil, traits: traits[$0]) })
            if cacheBox.cache == nil {
                cacheBox.cache = layout.makeCache(subviews: subviews)
            } else {
                layout.updateCache(&cacheBox.cache!, subviews: subviews)
            }
            return LayoutEngineComputer(layout: layout, children: children, traits: traits, cacheBox: cacheBox, path: path, tracer: tracer)
        }
        computer.label = "layout \(path)"
        let geometry = inputs.geometry
        let placements = Attribute<Placements>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let engine = computer.value as! LayoutEngineComputer<L>
            tracer.record(.placement, path)
            return engine.place(in: geometry.value)
        }
        placements.label = "placements \(path)"
        container.placement = { index in
            let all = placements.value.geometries
            return index < all.count ? all[index] : .zero
        }
        if L.self == _ViewThatFitsLayout.self || L.self == AnyLayout.self {
            // Layouts that can hide subviews own the render membership of their children.
            let renderer = inputs.host.renderer
            let group = container.group
            container.ownsRenderMembership = true
            let membership = Attribute<[ObjectIdentifier]>(inputs.subgraph, isEqual: { $0 == $1 }) {
                let currentItems = items.value
                let hidden = placements.value.hidden
                let visible = currentItems.indices.filter { $0 >= hidden.count || !hidden[$0] }.map { currentItems[$0].group }
                renderer.setChildren(of: group, visible)
                return visible.map { ObjectIdentifier($0) }
            }
            membership.order = inputs.depth
            membership.isEager = true
        }
        var preferences = PreferenceOutputs()
        for key in inputs.preferenceKeys {
            preferences.values[key.id] = key.combine(dynamic: {
                items.value.compactMap { $0.outputs.preferences.values[key.id] }
            }, subgraph: inputs.subgraph)
        }
        return _ViewOutputs(layout: computer, preferences: preferences)
    }

    /// A list in a unary context: a single static element is built in place; otherwise children
    /// are stacked with `layout` (vertical stack by default, like SwiftUI).
    func makeUnary(list: ViewList) -> _ViewOutputs {
        makeUnary(list: list, layout: _UnaryListLayout())
    }

    func makeUnary(list: ViewList, layout: some Layout) -> _ViewOutputs {
        if let element = list.staticSingleElement {
            return element.make(self)
        }
        return makeLayoutContainer(layout: constant(layout), list: list)
    }
}

/// Layout used when a multi-view list appears where one view is expected. With one child it is
/// fully transparent (size, alignment, spacing, priority forwarded); with more it stacks vertically.
struct _UnaryListLayout: Layout {
    var stackLayout = _VStackLayout()

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        if subviews.isEmpty { return .zero }
        if subviews.count == 1 { return subviews[0].sizeThatFits(proposal) }
        var stackCache = stackLayout.makeCache(subviews: subviews)
        return stackLayout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &stackCache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin, proposal: proposal)
            return
        }
        var stackCache = stackLayout.makeCache(subviews: subviews)
        stackLayout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &stackCache)
    }
}

/// `Layout` used as a view: `MyLayout { ... }`.
public struct _LayoutRoot<L: Layout, Content: View>: View {
    let layout: L
    let content: Content

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: typeName(L.self))
        let content = view.project(inputs) { $0.content }
        let list = Content._makeViewList(view: content, inputs: inputs.listInputs)
        let layout = view.project(inputs) { $0.layout }
        return inputs.makeLayoutContainer(layout: layout.attribute, list: list.list)
    }
}

/// Type-erased layout (`AnyLayout`). Switching layouts keeps children's identity (and state).
public struct AnyLayout: Layout {
    let storage: any Layout
    public init<L: Layout>(_ layout: L) { storage = layout }

    public typealias Cache = Void

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        func open<L: Layout>(_ layout: L) -> CGSize {
            var c = layout.makeCache(subviews: subviews)
            return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &c)
        }
        return open(storage)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        func open<L: Layout>(_ layout: L) {
            var c = layout.makeCache(subviews: subviews)
            layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &c)
        }
        open(storage)
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? {
        func open<L: Layout>(_ layout: L) -> CGFloat? {
            var c = layout.makeCache(subviews: subviews)
            return layout.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &c)
        }
        return open(storage)
    }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? {
        func open<L: Layout>(_ layout: L) -> CGFloat? {
            var c = layout.makeCache(subviews: subviews)
            return layout.explicitAlignment(of: guide, in: bounds, proposal: proposal, subviews: subviews, cache: &c)
        }
        return open(storage)
    }

    public func spacing(subviews: Subviews, cache: inout Void) -> ViewSpacing {
        func open<L: Layout>(_ layout: L) -> ViewSpacing {
            var c = layout.makeCache(subviews: subviews)
            return layout.spacing(subviews: subviews, cache: &c)
        }
        return open(storage)
    }
}
