import Foundation
import Observation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// HSplitView / VSplitView: children separated by 1pt dividers that can be dragged. A child keeps
// its ideal size (or the size it was dragged to); the last child takes the remaining space.

public struct HSplitView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { _SplitView(axis: .horizontal, content: content) }
}

public struct VSplitView<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { _SplitView(axis: .vertical, content: content) }
}

struct _SplitView<Content: View>: View {
    let axis: Axis
    let content: Content
    @State private var sizes = _SplitSizes()

    var body: some View {
        let sizes = self.sizes
        let axis = self.axis
        _ListTransformView(content: content, transform: { list, inputs in
            list.mapElements(in: inputs.subgraph) { element in
                var copy = element
                copy.make = { placement in
                    let position = placement.listItem?.position(in: placement.subgraph)
                    let modifier = Attribute<_SplitPaneModifier>(placement.subgraph) {
                        let current = position?.value ?? ListItemPosition()
                        return _SplitPaneModifier(axis: axis, index: current.index, isLast: current.next == nil, sizes: sizes)
                    }
                    return _SplitPaneModifier._makeView(modifier: _GraphValue(modifier), inputs: placement) { element.make($0) }
                }
                return copy
            }
        }, layout: AnyLayout(_SplitLayout(axis: axis, overrides: sizes.overrides)))
    }
}

/// Dragged sizes (observable, so the layout follows drags).
@Observable @MainActor
final class _SplitSizes {
    var overrides: [Int: CGFloat] = [:]
}

extension _SplitSizes: _GraphComparable {
    nonisolated static func _isIdentical(_ lhs: _SplitSizes, _ rhs: _SplitSizes) -> Bool { lhs === rhs }
}

/// A pane: its divider (after it) with a drag handle.
struct _SplitPaneModifier: ViewModifier {
    let axis: Axis
    let index: Int
    let isLast: Bool
    let sizes: _SplitSizes
    @State private var start: CGFloat?

    func body(content: Content) -> some View {
        content.overlay(alignment: axis == .horizontal ? .trailing : .bottom) {
            if !isLast {
                // NSSplitView's thin divider in the 1pt gap after the pane.
                Rectangle().fill(Color.splitDivider)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                    .offset(x: axis == .horizontal ? 1 : 0, y: axis == .vertical ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: axis == .horizontal ? .trailing : .bottom) {
            if !isLast {
                GeometryReader { proxy in
                    let length = axis == .horizontal ? proxy.size.width : proxy.size.height
                    Color.clear
                        .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: axis == .horizontal ? .trailing : .bottom)
                        .offset(x: axis == .horizontal ? 5 : 0, y: axis == .vertical ? 5 : 0)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                            let begin = start ?? length
                            if start == nil { start = length }
                            let delta = axis == .horizontal ? value.translation.width : value.translation.height
                            sizes.overrides[index] = max(20, begin + delta)
                        }.onEnded { _ in start = nil })
                }
            }
        }
    }
}

struct _SplitLayout: Layout, Equatable {
    let axis: Axis
    let overrides: [Int: CGFloat]

    private func lengths(_ total: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let dividers = CGFloat(max(0, subviews.count - 1))
        var lengths = subviews.indices.map { index -> CGFloat in
            if let override = overrides[index] { return override }
            let ideal = subviews[index].sizeThatFits(.unspecified)
            return axis == .horizontal ? ideal.width : ideal.height
        }
        guard let total, !lengths.isEmpty else { return lengths }
        // The last pane takes what's left (at least its minimum).
        let others = lengths.dropLast().reduce(0, +)
        let lastIndex = lengths.count - 1
        let minimum = axis == .horizontal ? subviews[lastIndex].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width : subviews[lastIndex].sizeThatFits(ProposedViewSize(width: nil, height: 0)).height
        lengths[lastIndex] = max(minimum, total - others - dividers)
        return lengths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let main = axis == .horizontal ? proposal.width : proposal.height
        let lengths = lengths(main, subviews)
        let total = lengths.reduce(0, +) + CGFloat(max(0, subviews.count - 1))
        let cross = axis == .horizontal ? proposal.height : proposal.width
        var crossSize: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(axis == .horizontal ? ProposedViewSize(width: lengths[index], height: cross) : ProposedViewSize(width: cross, height: lengths[index]))
            crossSize = max(crossSize, axis == .horizontal ? size.height : size.width)
        }
        let finalCross = cross ?? crossSize
        return axis == .horizontal ? CGSize(width: main ?? total, height: finalCross) : CGSize(width: finalCross, height: main ?? total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let lengths = lengths(axis == .horizontal ? bounds.width : bounds.height, subviews)
        var position = axis == .horizontal ? bounds.minX : bounds.minY
        for (index, subview) in subviews.enumerated() {
            if axis == .horizontal {
                subview.place(at: CGPoint(x: position, y: bounds.minY), proposal: ProposedViewSize(width: lengths[index], height: bounds.height))
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: position), proposal: ProposedViewSize(width: bounds.width, height: lengths[index]))
            }
            position += lengths[index] + 1
        }
    }
}
