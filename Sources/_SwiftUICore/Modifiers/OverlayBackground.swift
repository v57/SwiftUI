import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// `.overlay` and `.background` — secondary content sized to, and aligned within, the primary view.
///
/// Isolation guarantee: the modifier's layout *is* the primary view's layout attribute (forwarded,
/// not wrapped), so nothing outside the modifier can ever depend on the secondary content's layout.
/// Changes inside the secondary content only recompute the secondary content's placement
/// (which depends on the primary's size, never the other way around).
enum SecondaryPlacement: Sendable {
    case below, above
}

@MainActor
func makeSecondaryLayer<Secondary: View>(
    secondary: _GraphValue<Secondary>,
    alignment: Attribute<Alignment>,
    placement: SecondaryPlacement,
    inputs: _ViewInputs,
    body: (_ViewInputs) -> _ViewOutputs
) -> _ViewOutputs {
    let renderer = inputs.host.renderer
    let component = placement == .above ? "@overlay" : "@background"
    let primaryGroup = renderer.makeGroup(path: inputs.path)
    let secondaryGroup = renderer.makeGroup(path: inputs.path.appending(component))
    // Z-order: background below primary, overlay above.
    if placement == .below {
        renderer.append(secondaryGroup, to: inputs.render.parent)
        renderer.append(primaryGroup, to: inputs.render.parent)
    } else {
        renderer.append(primaryGroup, to: inputs.render.parent)
        renderer.append(secondaryGroup, to: inputs.render.parent)
    }
    inputs.subgraph.onDestroy {
        renderer.remove(primaryGroup)
        renderer.remove(secondaryGroup)
    }

    var primaryInputs = inputs
    primaryInputs.render = _RenderInputs(parent: primaryGroup, origin: inputs.render.origin)
    let primary = body(primaryInputs)

    let secondaryPath = inputs.path.appending(component)
    let secondaryGeometry = inputs.makeChildGeometry(label: "geometry \(secondaryPath)")
    var secondaryInputs = inputs.child(geometry: secondaryGeometry, render: _RenderInputs(parent: secondaryGroup, origin: inputs.render.origin))
    secondaryInputs.path = secondaryPath
    secondaryInputs.stackAxis = nil
    let secondaryList = Secondary._makeViewList(view: secondary, inputs: secondaryInputs.listInputs)
    let zstack = Attribute<_ZStackLayout>(inputs.subgraph, isEqual: { $0 == $1 }) { _ZStackLayout(alignment: alignment.value) }
    let secondaryOutputs = secondaryInputs.makeUnary(list: secondaryList.list, layout: _ZStackListLayout(zstack: zstack))

    let geometry = inputs.geometry
    let primaryLayout = primary.layout
    let secondaryLayout = secondaryOutputs.layout
    let tracer = inputs.tracer
    secondaryGeometry.setRule {
        let placed = geometry.value
        let proposal = ProposedViewSize(placed.size)
        let content = secondaryLayout.value
        let size = content.sizeThatFits(proposal)
        tracer.record(.placement, secondaryPath)
        return placed.aligning(
            childSize: size,
            child: content,
            container: primaryLayout.value.dimensions(size: placed.size),
            alignment: alignment.value,
            proposal: proposal
        )
    }
    secondaryGeometry.onChange = { _ in tracer.record(.geometry, secondaryPath) }
    if secondaryOutputs.preferences.isEmpty { return primary }
    let ordered = placement == .below ? [secondaryOutputs.preferences, primary.preferences] : [primary.preferences, secondaryOutputs.preferences]
    return _ViewOutputs(layout: primary.layout, preferences: PreferenceOutputs.combine(ordered, keys: inputs.preferenceKeys, subgraph: inputs.subgraph))
}

/// Unary layout for multi-view overlay/background content: views are z-stacked.
struct _ZStackListLayout: Layout {
    let zstack: Attribute<_ZStackLayout>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        if subviews.count == 1 { return subviews[0].sizeThatFits(proposal) }
        return zstack.value.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        zstack.value.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }
}

extension _ZStackListLayout: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: _ZStackListLayout, _ rhs: _ZStackListLayout) -> Bool {
        lhs.zstack === rhs.zstack
    }
}

public struct _OverlayModifier<Overlay: View>: ViewModifier {
    public var overlay: Overlay
    public var alignment: Alignment
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let overlay = modifier.project(inputs) { $0.overlay }
        let alignment = Attribute<Alignment>(inputs.subgraph, isEqual: { $0 == $1 }) { modifier.value.alignment }
        return makeSecondaryLayer(secondary: overlay, alignment: alignment, placement: .above, inputs: inputs, body: body)
    }
}

public struct _BackgroundModifier<Background: View>: ViewModifier {
    public var background: Background
    public var alignment: Alignment
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let background = modifier.project(inputs) { $0.background }
        let alignment = Attribute<Alignment>(inputs.subgraph, isEqual: { $0 == $1 }) { modifier.value.alignment }
        return makeSecondaryLayer(secondary: background, alignment: alignment, placement: .below, inputs: inputs, body: body)
    }
}

extension View {
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(_OverlayModifier(overlay: content(), alignment: alignment))
    }

    @_disfavoredOverload public func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> some View {
        modifier(_OverlayModifier(overlay: overlay, alignment: alignment))
    }

    /// Safe areas are not modeled, so `ignoresSafeAreaEdges` has no effect.
    public func overlay<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        modifier(_OverlayModifier(overlay: Rectangle().fill(style), alignment: .center))
    }

    public func overlay<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        modifier(_OverlayModifier(overlay: shape.fill(style, style: fillStyle), alignment: .center))
    }

    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        modifier(_BackgroundModifier(background: content(), alignment: alignment))
    }

    @_disfavoredOverload public func background<V: View>(_ background: V, alignment: Alignment = .center) -> some View {
        modifier(_BackgroundModifier(background: background, alignment: alignment))
    }

    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        modifier(_BackgroundModifier(background: Rectangle().fill(style), alignment: .center))
    }

    /// The environment's background style (`backgroundStyle`, else the window background).
    public func background(ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        background(BackgroundStyle(), ignoresSafeAreaEdges: edges)
    }

    public func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        modifier(_BackgroundModifier(background: shape.fill(style, style: fillStyle), alignment: .center))
    }

    public func background<T: Shape>(in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        background(BackgroundStyle(), in: shape, fillStyle: fillStyle)
    }

    public func border<S: ShapeStyle>(_ content: S, width: CGFloat = 1) -> some View {
        overlay(Rectangle().strokeBorder(content, lineWidth: width))
    }
}
