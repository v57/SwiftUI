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
            return .scrollView(ResolvedScrollView(
                axes: axes.value,
                contentSize: placed.size,
                contentOrigin: placed.origin,
                showsIndicators: view.attribute.value.showsIndicators,
                requestedOffset: currentRequest.offset,
                scrollRequestID: currentRequest.id,
                isScrollEnabled: !environment.value.scrollDisabled
            ))
        }
        var actions = RenderActions()
        actions.scrolled = { point in offset.setValue(point) }
        let render = inputs.makePlatformNode(content: content, actions: actions, childOrigin: zero)
        var contentInputs = inputs.child(geometry: contentGeometry, render: render)
        contentInputs.stackAxis = nil
        let scrollTransform = Attribute<CGPoint>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let origin = geometry.value.origin
            let scrolled = offset.value
            return CGPoint(x: origin.x - scrolled.x, y: origin.y - scrolled.y)
        }
        contentInputs.coordinateSpaces = CoordinateSpaces(scrollTransform: scrollTransform, parent: inputs.coordinateSpaces)
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
            let proposal = ProposedViewSize(
                width: scrollAxes.contains(.horizontal) ? nil : viewport.width,
                height: scrollAxes.contains(.vertical) ? nil : viewport.height
            )
            let size = contentLayout.value.sizeThatFits(proposal)
            tracer.record(.placement, path)
            // Content smaller than the viewport is centered along non-scrolling axes.
            let x = scrollAxes.contains(.horizontal) ? 0 : (viewport.width - size.width) / 2
            let y = scrollAxes.contains(.vertical) ? 0 : (viewport.height - size.height) / 2
            return ViewGeometry(origin: CGPoint(x: x, y: y), size: size, proposal: proposal)
        }
        let layout = inputs.makeLayoutAttribute {
            ScrollViewComputer(axes: axes.value, path: path, tracer: tracer, content: contentLayout.value)
        }
        return _ViewOutputs(layout: layout, preferences: contentOutputs.preferences)
    }
}

/// Scroll views are flexible along scrolling axes; content changes never affect the parent.
final class ScrollViewComputer: LayoutComputer {
    let axes: Axis.Set
    let content: LayoutComputer

    init(axes: Axis.Set, path: ViewPath, tracer: UpdateTracer, content: LayoutComputer) {
        self.axes = axes
        self.content = content
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize {
        let ideal = content.sizeThatFits(ProposedViewSize(
            width: axes.contains(.horizontal) ? nil : proposal.width,
            height: axes.contains(.vertical) ? nil : proposal.height
        ))
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        (other as? ScrollViewComputer)?.axes == axes
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

    @MainActor
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

    @MainActor
    public func frame(in space: NamedCoordinateSpace) -> CGRect {
        frame(in: CoordinateSpace.named(space.name))
    }
}

extension GeometryProxy: Equatable {
    public static func == (lhs: GeometryProxy, rhs: GeometryProxy) -> Bool { lhs.geometry == rhs.geometry }
}

public enum CoordinateSpace: Hashable, @unchecked Sendable {
    case global, local
    case named(AnyHashable)
}

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
        let proxy = Attribute<GeometryProxy>(inputs.subgraph, isEqual: { $0 == $1 }) { GeometryProxy(geometry: geometry.value, spaces: spaces) }
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
