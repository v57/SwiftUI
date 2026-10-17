import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - ScrollView

public struct ScrollView<Content: View>: View {
    public var content: Content
    public var axes: Axis.Set
    public var showsIndicators: Bool

    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "ScrollView")
        let axes = Attribute<Axis.Set>(inputs.subgraph, isEqual: { $0 == $1 }) { view.attribute.value.axes }
        let geometry = inputs.geometry
        // Content lives in its own coordinate space (origin = top-left of the scrollable content).
        let contentGeometry = inputs.makeChildGeometry(label: "scroll content \(inputs.path)")
        let zero = inputs.constant(CGPoint.zero)
        // Scroll offset reported by the backend; requests come from ScrollViewReader.
        let offset = Attribute<CGPoint>(inputs.subgraph, value: .zero, isEqual: { $0 == $1 })
        let request = Attribute<ScrollRequest>(inputs.subgraph, value: ScrollRequest(id: 0, offset: nil), isEqual: { $0 == $1 })
        let environment = inputs.environment
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let placed = contentGeometry.value
            let currentRequest = request.value
            let env = environment.value
            let configuration = env.scrollConfiguration
            let margins = configuration.contentMargins
            return .scrollView(ResolvedScrollView(
                axes: axes.value,
                contentSize: CGSize(width: placed.size.width + margins.trailing, height: placed.size.height + margins.bottom),
                contentOrigin: placed.origin,
                showsIndicators: view.attribute.value.showsIndicators,
                requestedOffset: currentRequest.offset,
                scrollRequestID: currentRequest.id,
                isScrollEnabled: !env.scrollDisabled,
                verticalIndicator: configuration.verticalIndicator,
                horizontalIndicator: configuration.horizontalIndicator,
                verticalBounce: configuration.verticalBounce,
                horizontalBounce: configuration.horizontalBounce,
                clipsContent: !configuration.clipDisabled,
                initialAnchor: configuration.defaultAnchor,
                flashCount: configuration.flashCount
            ))
        }
        var actions = RenderActions()
        actions.scrolled = { point in offset.setValue(point) }
        actions.scrollPhase = { phase in
            let (observers, scrollGeometry) = AnyAttribute.withoutDependencies {
                (environment.value.scrollPhaseObservers,
                 ScrollGeometry(contentOffset: offset.value, contentSize: contentGeometry.value.size, contentInsets: environment.value.scrollConfiguration.contentMargins, containerSize: geometry.value.size))
            }
            for observer in observers where observer.phase != phase {
                let old = observer.phase
                observer.phase = phase
                observer.action?(old, phase, ScrollPhaseChangeContext(geometry: scrollGeometry))
            }
        }
        let targetsRef = _ScrollTargetsRef()
        actions.scrollSnapTarget = { point in
            AnyAttribute.withoutDependencies {
                let viewport = geometry.value.size
                let contentSize = contentGeometry.value.size
                let scrollAxes = axes.value
                let maxOffset = CGPoint(x: max(0, contentSize.width - viewport.width), y: max(0, contentSize.height - viewport.height))
                switch environment.value.scrollConfiguration.targetBehavior {
                case .none:
                    return nil
                case .paging:
                    func page(_ value: CGFloat, _ length: CGFloat, _ limit: CGFloat) -> CGFloat {
                        length > 0 ? min(limit, (value / length).rounded() * length) : value
                    }
                    return CGPoint(x: scrollAxes.contains(.horizontal) ? page(point.x, viewport.width, maxOffset.x) : point.x,
                                   y: scrollAxes.contains(.vertical) ? page(point.y, viewport.height, maxOffset.y) : point.y)
                case .viewAligned:
                    // The target whose leading edge is nearest to the resting offset.
                    guard let targets = targetsRef.targets else { return nil }
                    let vertical = scrollAxes.contains(.vertical)
                    let edges = targets.allIDs.compactMap { targets.frame(for: $0) }.map { vertical ? $0.minY : $0.minX }
                    let current = vertical ? point.y : point.x
                    guard let nearest = edges.min(by: { abs($0 - current) < abs($1 - current) }) else { return nil }
                    return vertical ? CGPoint(x: point.x, y: min(max(0, nearest), maxOffset.y)) : CGPoint(x: min(max(0, nearest), maxOffset.x), y: point.y)
                }
            }
        }
        let render = inputs.makePlatformNode(content: content, actions: actions, childOrigin: zero)
        var contentInputs = inputs.child(geometry: contentGeometry, render: render)
        contentInputs.stackAxis = nil
        let scrollTransform = Attribute<CGPoint>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let origin = geometry.value.origin
            let scrolled = offset.value
            return CGPoint(x: origin.x - scrolled.x, y: origin.y - scrolled.y)
        }
        let boundary = CoordinateSpaces(scrollTransform: scrollTransform, parent: inputs.coordinateSpaces)
        // `.scrollView`: the visible region (content point minus the content offset).
        let viewportSize = Attribute<CGSize>(inputs.subgraph, isEqual: { $0 == $1 }) { geometry.value.size }
        contentInputs.coordinateSpaces = CoordinateSpaces(name: AnyHashable(_ScrollViewCoordinateSpaceName()), origin: offset, size: viewportSize, parent: boundary)
        contentInputs.scrollViewport = Attribute<CGRect>(inputs.subgraph, isEqual: { $0 == $1 }) {
            CGRect(origin: offset.value, size: geometry.value.size)
        }
        let targets = ScrollTargets(axes: AnyAttribute.withoutDependencies { axes.value })
        contentInputs.scrollTargets = targets
        targets.scroll = { target, anchor in
            AnyAttribute.withoutDependencies {
                let viewport = geometry.value.size
                let contentSize = contentGeometry.value.size
                let unit = anchor ?? .top
                var point = CGPoint(
                    x: target.minX - (viewport.width - target.width) * unit.x,
                    y: target.minY - (viewport.height - target.height) * unit.y
                )
                point.x = max(0, min(point.x, max(0, contentSize.width - viewport.width)))
                point.y = max(0, min(point.y, max(0, contentSize.height - viewport.height)))
                let current = request.peekValue ?? ScrollRequest(id: 0, offset: nil)
                request.setValue(ScrollRequest(id: current.id + 1, offset: point))
                offset.setValue(point)
            }
        }
        targetsRef.targets = targets
        if let box = AnyAttribute.withoutDependencies({ environment.value.scrollProxyBox }) {
            box.targets = targets
        }
        let isHorizontal = AnyAttribute.withoutDependencies { axes.value } == .horizontal
        let list = Content._makeViewList(view: view.project(inputs) { $0.content }, inputs: contentInputs.listInputs)
        let contentOutputs = isHorizontal
            ? contentInputs.makeUnary(list: list.list, layout: _HStackLayout())
            : contentInputs.makeUnary(list: list.list)
        let contentLayout = contentOutputs.layout
        let tracer = inputs.tracer
        let path = inputs.path
        contentGeometry.setRule {
            let viewport = geometry.value.size
            let scrollAxes = axes.value
            let margins = environment.value.scrollConfiguration.contentMargins
            let proposal = ProposedViewSize(
                width: scrollAxes.contains(.horizontal) ? nil : max(0, viewport.width - margins.horizontal),
                height: scrollAxes.contains(.vertical) ? nil : max(0, viewport.height - margins.vertical)
            )
            let size = contentLayout.value.sizeThatFits(proposal)
            tracer.record(.placement, path)
            // Content smaller than the viewport is centered along non-scrolling axes.
            let x = scrollAxes.contains(.horizontal) ? margins.leading : margins.leading + (viewport.width - margins.horizontal - size.width) / 2
            let y = scrollAxes.contains(.vertical) ? margins.top : margins.top + (viewport.height - margins.vertical - size.height) / 2
            return ViewGeometry(origin: CGPoint(x: x, y: y), size: size, proposal: proposal)
        }
        let layout = inputs.makeLayoutAttribute {
            ScrollViewComputer(axes: axes.value, margins: environment.value.scrollConfiguration.contentMargins, path: path, tracer: tracer, content: contentLayout.value)
        }
        // onScrollGeometryChange: observers get the live geometry after each update.
        let host = inputs.host
        let geometryReporter = Attribute<ScrollGeometry>(inputs.subgraph, isEqual: { $0 == $1 }) {
            ScrollGeometry(contentOffset: offset.value, contentSize: contentGeometry.value.size, contentInsets: EdgeInsets(), containerSize: geometry.value.size)
        }
        geometryReporter.onChange = { [weak targets] scrollGeometry in
            let (observers, visibilityObservers) = AnyAttribute.withoutDependencies {
                (environment.value.scrollGeometryObservers, environment.value.scrollTargetVisibilityObservers)
            }
            if !observers.isEmpty {
                host.enqueueAfterUpdate { for observer in observers { observer.update(scrollGeometry) } }
            }
            if !visibilityObservers.isEmpty, let targets {
                host.enqueueAfterUpdate {
                    let viewport = scrollGeometry.visibleRect
                    let frames = targets.allIDs.compactMap { id in targets.frame(for: id).map { (id, $0) } }
                        .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
                    for observer in visibilityObservers {
                        let visible = frames.filter { visibleFraction(of: $0.1, in: viewport) >= observer.threshold }.map(\.0)
                        guard visible != observer.last else { continue }
                        observer.last = visible
                        observer.update?(visible)
                    }
                }
            }
        }
        geometryReporter.isEager = AnyAttribute.withoutDependencies {
            !environment.value.scrollGeometryObservers.isEmpty || !environment.value.scrollTargetVisibilityObservers.isEmpty
        }
        return _ViewOutputs(layout: layout, preferences: contentOutputs.preferences)
    }
}

@MainActor final class _ScrollTargetsRef { weak var targets: ScrollTargets? }

/// Scroll views are flexible along their scrolling axes and take their content's size on the
/// other axis (measured on macOS SwiftUI). Content changes affect the parent only when they change
/// an answer the parent already got, so growth along the scrolling axis stays isolated.
final class ScrollViewComputer: LayoutComputer {
    let axes: Axis.Set
    let margins: EdgeInsets
    private(set) var content: LayoutComputer

    init(axes: Axis.Set, margins: EdgeInsets = EdgeInsets(), path: ViewPath, tracer: UpdateTracer, content: LayoutComputer) {
        self.axes = axes
        self.margins = margins
        self.content = content
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let fitted = content.sizeThatFits(ProposedViewSize(
            width: axes.contains(.horizontal) ? nil : proposal.width.map { max(0, $0 - margins.horizontal) },
            height: axes.contains(.vertical) ? nil : proposal.height.map { max(0, $0 - margins.vertical) }
        ))
        return CGSize(
            width: axes.contains(.horizontal) ? proposal.width ?? fitted.width + margins.horizontal : fitted.width + margins.horizontal,
            height: axes.contains(.vertical) ? proposal.height ?? fitted.height + margins.vertical : fitted.height + margins.vertical
        )
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? ScrollViewComputer, other.axes == axes, other.margins == margins else { return false }
        for (proposal, size) in other.answeredSizes where sizeThatFits(proposal) != size { return false }
        // The previous computer stays in place; let it measure the current content from now on.
        other.content = content
        return true
    }
}

// MARK: - GeometryReader

public struct GeometryProxy {
    let geometry: ViewGeometry
    var spaces: CoordinateSpaces?

    init(geometry: ViewGeometry, spaces: CoordinateSpaces? = nil) {
        self.geometry = geometry
        self.spaces = spaces
    }

    public var size: CGSize { geometry.size }
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }

    /// The bounds of a named coordinate space (`.scrollView`: the scroll view's visible region) in
    /// this view's local coordinates; nil when no such space encloses the view.
    @MainActor
    public func bounds(of coordinateSpace: NamedCoordinateSpace) -> CGRect? {
        guard let bounds = spaces?.bounds(of: coordinateSpace.name) else { return nil }
        return bounds.offsetBy(dx: -geometry.origin.x, dy: -geometry.origin.y)
    }

    @MainActor
    public func frame(in coordinateSpace: some CoordinateSpaceProtocol) -> CGRect {
        frame(in: coordinateSpace.coordinateSpace)
    }

    @MainActor @_disfavoredOverload
    public func frame(in coordinateSpace: CoordinateSpace) -> CGRect {
        switch coordinateSpace {
        case .local: return CGRect(origin: .zero, size: geometry.size)
        case .global:
            let offset = spaces?.globalOffset() ?? .zero
            return geometry.frame.offsetBy(dx: offset.x, dy: offset.y)
        case .named(let name):
            // Unknown names behave like the global space (as in SwiftUI).
            let offset = spaces?.offset(to: name) ?? spaces?.globalOffset() ?? .zero
            return geometry.frame.offsetBy(dx: offset.x, dy: offset.y)
        }
    }

}

extension GeometryProxy: Equatable {
    public static func == (lhs: GeometryProxy, rhs: GeometryProxy) -> Bool { lhs.geometry == rhs.geometry }
}

public enum CoordinateSpace: Hashable, @unchecked Sendable {
    case global, local
    case named(AnyHashable)
}

/// A coordinate space for geometry and gestures (`.local`, `.global`, `.named(_:)`).
public protocol CoordinateSpaceProtocol {
    var coordinateSpace: CoordinateSpace { get }
}

public struct LocalCoordinateSpace: CoordinateSpaceProtocol {
    public init() {}
    public var coordinateSpace: CoordinateSpace { .local }
}

public struct GlobalCoordinateSpace: CoordinateSpaceProtocol {
    public init() {}
    public var coordinateSpace: CoordinateSpace { .global }
}

extension NamedCoordinateSpace: CoordinateSpaceProtocol {
    public var coordinateSpace: CoordinateSpace { .named(name) }
}

extension CoordinateSpaceProtocol where Self == LocalCoordinateSpace {
    public static var local: LocalCoordinateSpace { LocalCoordinateSpace() }
}

extension CoordinateSpaceProtocol where Self == GlobalCoordinateSpace {
    public static var global: GlobalCoordinateSpace { GlobalCoordinateSpace() }
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    public static func named(_ name: some Hashable) -> NamedCoordinateSpace { NamedCoordinateSpace(name: AnyHashable(name)) }
    /// The coordinate space of the nearest enclosing scroll view's content.
    public static var scrollView: NamedCoordinateSpace { NamedCoordinateSpace(name: AnyHashable(_ScrollViewCoordinateSpaceName())) }
    public static func scrollView(axis: Axis) -> NamedCoordinateSpace { scrollView }
}

struct _ScrollViewCoordinateSpaceName: Hashable {}

public struct GeometryReader<Content: View>: View {
    public var content: (GeometryProxy) -> Content

    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {
        self.content = content
    }

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "GeometryReader")
        let geometry = inputs.geometry
        let spaces = inputs.coordinateSpaces
        // The content can be evaluated while the view graph is still being built (a descendant
        // reading static information), before the parent has bound this reader's geometry.
        let proxy = Attribute<GeometryProxy>(inputs.subgraph, isEqual: { $0 == $1 }) {
            GeometryProxy(geometry: geometry.valueIfPresent ?? ViewGeometry(origin: .zero, size: .zero, proposal: .unspecified), spaces: spaces)
        }
        let contentView = Attribute<Content>(inputs.subgraph)
        contentView.setRule { [unowned contentView] in
            let reader = view.attribute.value
            let currentProxy = proxy.value
            return observingChanges(invalidating: contentView) { reader.content(currentProxy) }
        }
        let contentGeometry = inputs.makeChildGeometry()
        var contentInputs = inputs.child(geometry: contentGeometry)
        contentInputs.stackAxis = nil
        let list = Content._makeViewList(view: _GraphValue(contentView), inputs: contentInputs.listInputs)
        let contentOutputs = contentInputs.makeUnary(list: list.list, layout: _ZStackLayout(alignment: .topLeading))
        let contentLayout = contentOutputs.layout
        contentGeometry.setRule {
            let placed = geometry.value
            let size = contentLayout.value.sizeThatFits(ProposedViewSize(placed.size))
            return ViewGeometry(origin: placed.origin, size: size, proposal: ProposedViewSize(placed.size))
        }
        let tracer = inputs.tracer
        let path = inputs.path
        // Layout boundary: the reader takes the proposed size whatever its content does.
        return _ViewOutputs(layout: inputs.makeLayoutAttribute { FlexibleLayoutComputer(path: path, tracer: tracer) }, preferences: contentOutputs.preferences)
    }
}
