import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Path

public struct Path: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case closeSubpath
    }

    public private(set) var elements: [Element] = []

    public init() {}

    public init(_ rect: CGRect) {
        addRect(rect)
    }

    public init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
    }

    public init(ellipseIn rect: CGRect) {
        addEllipse(in: rect)
    }

    public init(_ build: (inout Path) -> Void) {
        build(&self)
    }

    public var isEmpty: Bool { elements.isEmpty }

    public mutating func move(to point: CGPoint) { elements.append(.move(to: point)) }
    public mutating func addLine(to point: CGPoint) { elements.append(.line(to: point)) }
    public mutating func addQuadCurve(to point: CGPoint, control: CGPoint) { elements.append(.quadCurve(to: point, control: control)) }
    public mutating func addCurve(to point: CGPoint, control1: CGPoint, control2: CGPoint) {
        elements.append(.curve(to: point, control1: control1, control2: control2))
    }
    public mutating func closeSubpath() { elements.append(.closeSubpath) }

    public mutating func addLines(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() { addLine(to: point) }
    }

    public mutating func addRect(_ rect: CGRect) {
        move(to: CGPoint(x: rect.minX, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        closeSubpath()
    }

    public mutating func addRoundedRect(in rect: CGRect, cornerSize: CGSize) {
        let rx = min(cornerSize.width, rect.width / 2)
        let ry = min(cornerSize.height, rect.height / 2)
        guard rx > 0, ry > 0 else { return addRect(rect) }
        let k: CGFloat = 0.5523 // circle approximation constant
        move(to: CGPoint(x: rect.minX + rx, y: rect.minY))
        addLine(to: CGPoint(x: rect.maxX - rx, y: rect.minY))
        addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + ry), control1: CGPoint(x: rect.maxX - rx + rx * k, y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.minY + ry - ry * k))
        addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - ry))
        addCurve(to: CGPoint(x: rect.maxX - rx, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.maxY - ry + ry * k), control2: CGPoint(x: rect.maxX - rx + rx * k, y: rect.maxY))
        addLine(to: CGPoint(x: rect.minX + rx, y: rect.maxY))
        addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - ry), control1: CGPoint(x: rect.minX + rx - rx * k, y: rect.maxY), control2: CGPoint(x: rect.minX, y: rect.maxY - ry + ry * k))
        addLine(to: CGPoint(x: rect.minX, y: rect.minY + ry))
        addCurve(to: CGPoint(x: rect.minX + rx, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.minY + ry - ry * k), control2: CGPoint(x: rect.minX + rx - rx * k, y: rect.minY))
        closeSubpath()
    }

    public mutating func addEllipse(in rect: CGRect) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: rect.width / 2, height: rect.height / 2))
    }

    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool) {
        // Approximated with line segments (SwiftUI's y-down "clockwise" convention).
        var start = startAngle.radians
        var end = endAngle.radians
        if clockwise {
            while end > start { end -= 2 * .pi }
        } else {
            while end < start { end += 2 * .pi }
        }
        let segments = max(4, Int(abs(end - start) / (.pi / 16)))
        for index in 0...segments {
            let angle = start + (end - start) * Double(index) / Double(segments)
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if index == 0 && elements.isEmpty { move(to: point) } else { addLine(to: point) }
        }
        start = end
    }

    public mutating func addPath(_ path: Path) { elements.append(contentsOf: path.elements) }

    public var boundingRect: CGRect {
        var points: [CGPoint] = []
        for element in elements {
            switch element {
            case .move(let p), .line(let p): points.append(p)
            case let .quadCurve(p, c): points += [p, c]
            case let .curve(p, c1, c2): points += [p, c1, c2]
            case .closeSubpath: break
            }
        }
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }

    public func applying(_ transform: CGAffineTransform) -> Path {
        func map(_ p: CGPoint) -> CGPoint { p.applying(transform) }
        var copy = Path()
        copy.elements = elements.map {
            switch $0 {
            case .move(let p): return .move(to: map(p))
            case .line(let p): return .line(to: map(p))
            case let .quadCurve(p, c): return .quadCurve(to: map(p), control: map(c))
            case let .curve(p, c1, c2): return .curve(to: map(p), control1: map(c1), control2: map(c2))
            case .closeSubpath: return .closeSubpath
            }
        }
        return copy
    }

    /// Polyline approximation (curves subdivided), grouped by subpath.
    func flattened() -> [[CGPoint]] {
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func last() -> CGPoint { current.last ?? start }
        for element in elements {
            switch element {
            case .move(let p):
                if current.count > 1 { subpaths.append(current) }
                current = [p]
                start = p
            case .line(let p):
                current.append(p)
            case let .quadCurve(p, c):
                let p0 = last()
                for step in 1...12 {
                    let t = CGFloat(step) / 12
                    let x = (1 - t) * (1 - t) * p0.x + 2 * (1 - t) * t * c.x + t * t * p.x
                    let y = (1 - t) * (1 - t) * p0.y + 2 * (1 - t) * t * c.y + t * t * p.y
                    current.append(CGPoint(x: x, y: y))
                }
            case let .curve(p, c1, c2):
                let p0 = last()
                for step in 1...16 {
                    let t = CGFloat(step) / 16
                    let u = 1 - t
                    let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x
                    let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
                    current.append(CGPoint(x: x, y: y))
                }
            case .closeSubpath:
                current.append(start)
            }
        }
        if current.count > 1 { subpaths.append(current) }
        return subpaths
    }

    /// The portion of the path between fractions `from` and `to` of its length.
    public func trimmedPath(from: CGFloat, to: CGFloat) -> Path {
        let from = max(0, min(1, from)), to = max(0, min(1, to))
        guard to > from else { return Path() }
        if from == 0, to == 1 { return self }
        let polylines = flattened()
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot() }
        let total = polylines.reduce(CGFloat(0)) { sum, line in sum + zip(line, line.dropFirst()).reduce(0) { $0 + length($1.0, $1.1) } }
        guard total > 0 else { return Path() }
        let startDistance = from * total, endDistance = to * total
        var result = Path()
        var travelled: CGFloat = 0
        for line in polylines {
            var started = false
            for (a, b) in zip(line, line.dropFirst()) {
                let segment = length(a, b)
                let segStart = travelled, segEnd = travelled + segment
                travelled = segEnd
                guard segEnd >= startDistance, segStart <= endDistance, segment > 0 else { continue }
                let t0 = max(0, (startDistance - segStart) / segment)
                let t1 = min(1, (endDistance - segStart) / segment)
                let p0 = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                let p1 = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                if !started {
                    result.move(to: p0)
                    started = true
                }
                result.addLine(to: p1)
            }
        }
        return result
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Path {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var copy = Path()
        copy.elements = elements.map {
            switch $0 {
            case .move(let p): return .move(to: shift(p))
            case .line(let p): return .line(to: shift(p))
            case let .quadCurve(p, c): return .quadCurve(to: shift(p), control: shift(c))
            case let .curve(p, c1, c2): return .curve(to: shift(p), control1: shift(c1), control2: shift(c2))
            case .closeSubpath: return .closeSubpath
            }
        }
        return copy
    }
}

// MARK: - Shape

@MainActor @preconcurrency
public protocol Shape: View, Animatable {
    func path(in rect: CGRect) -> Path
    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize
}

/// Shapes that can be inset (needed by `strokeBorder`).
@MainActor @preconcurrency
public protocol InsettableShape: Shape {
    associatedtype InsetShape: InsettableShape
    func inset(by amount: CGFloat) -> InsetShape
}

extension Shape {
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    public var body: _ShapeView<Self, ForegroundStyle> { _ShapeView(shape: self, style: ForegroundStyle(), stroke: nil) }

    public func fill<S: ShapeStyle>(_ style: S, style fillStyle: FillStyle = FillStyle()) -> _ShapeView<Self, S> {
        _ShapeView(shape: self, style: style, stroke: nil)
    }

    public func fill(style fillStyle: FillStyle = FillStyle()) -> _ShapeView<Self, ForegroundStyle> {
        _ShapeView(shape: self, style: ForegroundStyle(), stroke: nil)
    }

    public func stroke<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1) -> _ShapeView<Self, S> {
        _ShapeView(shape: self, style: style, stroke: StrokeStyle(lineWidth: lineWidth))
    }

    public func stroke<S: ShapeStyle>(_ style: S, style strokeStyle: StrokeStyle) -> _ShapeView<Self, S> {
        _ShapeView(shape: self, style: style, stroke: strokeStyle)
    }

    public func stroke(lineWidth: CGFloat = 1) -> _ShapeView<Self, ForegroundStyle> {
        _ShapeView(shape: self, style: ForegroundStyle(), stroke: StrokeStyle(lineWidth: lineWidth))
    }

    public func stroke(style strokeStyle: StrokeStyle) -> _ShapeView<Self, ForegroundStyle> {
        _ShapeView(shape: self, style: ForegroundStyle(), stroke: strokeStyle)
    }

    public func trim(from: CGFloat = 0, to: CGFloat = 1) -> _TrimmedShape<Self> { _TrimmedShape(base: self, from: from, to: to) }
    public func offset(_ offset: CGSize) -> _OffsetShape<Self> { _OffsetShape(base: self, offset: offset) }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> _OffsetShape<Self> { _OffsetShape(base: self, offset: CGSize(width: x, height: y)) }
    public func rotation(_ angle: Angle, anchor: UnitPoint = .center) -> _RotatedShape<Self> { _RotatedShape(base: self, angle: angle, anchor: anchor) }
    public func scale(_ scale: CGFloat, anchor: UnitPoint = .center) -> _ScaledShape<Self> { _ScaledShape(base: self, scale: CGSize(width: scale, height: scale), anchor: anchor) }
    public func scale(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> _ScaledShape<Self> { _ScaledShape(base: self, scale: CGSize(width: x, height: y), anchor: anchor) }
}

extension Shape {
    public func strokeBorder<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1) -> _ShapeView<_InsetShape<Self>, S> {
        _ShapeView(shape: _InsetShape(base: self, inset: lineWidth / 2), style: style, stroke: StrokeStyle(lineWidth: lineWidth))
    }

    public func strokeBorder(lineWidth: CGFloat = 1) -> _ShapeView<_InsetShape<Self>, ForegroundStyle> {
        _ShapeView(shape: _InsetShape(base: self, inset: lineWidth / 2), style: ForegroundStyle(), stroke: StrokeStyle(lineWidth: lineWidth))
    }

    public func strokeBorder<S: ShapeStyle>(_ style: S, style strokeStyle: StrokeStyle) -> _ShapeView<_InsetShape<Self>, S> {
        _ShapeView(shape: _InsetShape(base: self, inset: strokeStyle.lineWidth / 2), style: style, stroke: strokeStyle)
    }
}

extension Shape {
    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let shapeView = view.project(inputs) { _ShapeView(shape: $0, style: ForegroundStyle(), stroke: nil) }
        return _ShapeView<Self, ForegroundStyle>._makeView(view: shapeView, inputs: inputs)
    }

    public static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        .unary(view: view, inputs: inputs)
    }
}

public struct _InsetShape<Base: Shape>: InsettableShape {
    let base: Base
    let inset: CGFloat
    public func path(in rect: CGRect) -> Path {
        if let rounded = base as? RoundedRectangle {
            return RoundedRectangle(cornerSize: CGSize(width: max(0, rounded.cornerSize.width - inset), height: max(0, rounded.cornerSize.height - inset))).path(in: rect.insetBy(dx: inset, dy: inset))
        }
        return base.path(in: rect.insetBy(dx: inset, dy: inset))
    }
    public func inset(by amount: CGFloat) -> _InsetShape<Base> { _InsetShape(base: base, inset: inset + amount) }
}

extension Shape {
    public func inset(by amount: CGFloat) -> _InsetShape<Self> { _InsetShape(base: self, inset: amount) }
}

public struct _TrimmedShape<Base: Shape>: Shape {
    let base: Base
    var from: CGFloat
    var to: CGFloat
    public func path(in rect: CGRect) -> Path { base.path(in: rect).trimmedPath(from: from, to: to) }
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(from, to) }
        set { (from, to) = (newValue.first, newValue.second) }
    }
}

public struct _OffsetShape<Base: Shape>: Shape {
    let base: Base
    let offset: CGSize
    public func path(in rect: CGRect) -> Path { base.path(in: rect).offsetBy(dx: offset.width, dy: offset.height) }
}

public struct _RotatedShape<Base: Shape>: Shape {
    let base: Base
    let angle: Angle
    let anchor: UnitPoint
    public func path(in rect: CGRect) -> Path {
        let ax = rect.minX + anchor.x * rect.width, ay = rect.minY + anchor.y * rect.height
        let transform = CGAffineTransform(translationX: ax, y: ay).rotated(by: CGFloat(angle.radians)).translatedBy(x: -ax, y: -ay)
        return base.path(in: rect).applying(transform)
    }
}

public struct _ScaledShape<Base: Shape>: Shape {
    let base: Base
    let scale: CGSize
    let anchor: UnitPoint
    public func path(in rect: CGRect) -> Path {
        let ax = rect.minX + anchor.x * rect.width, ay = rect.minY + anchor.y * rect.height
        let transform = CGAffineTransform(translationX: ax, y: ay).scaledBy(x: scale.width, y: scale.height).translatedBy(x: -ax, y: -ay)
        return base.path(in: rect).applying(transform)
    }
}

/// Type-erased shape.
public struct AnyShape: Shape {
    let make: @MainActor (CGRect) -> Path
    public init<S: Shape>(_ shape: S) { make = { shape.path(in: $0) } }
    public func path(in rect: CGRect) -> Path { make(rect) }
}

extension Path: Shape {
    public func path(in rect: CGRect) -> Path { self }
}

/// Primitive view that renders a shape.
public struct _ShapeView<S: Shape, Style: ShapeStyle>: View {
    let shape: S
    let style: Style
    let stroke: StrokeStyle?

    public var body: Never { primitiveBody(Self.self) }

    public static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let inputs = inputs.with(path: typeName(S.self))
        let environment = inputs.environment
        let geometry = inputs.geometry
        // Animatable shapes (trim, custom animatableData) interpolate per frame.
        let shape = animatedIfNeeded(Attribute<S>(inputs.subgraph) { view.attribute.value.shape }, host: inputs.host, scope: inputs.animationScope, subgraph: inputs.subgraph)
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            let shapeView = view.attribute.value
            let size = geometry.value.size
            let paint = shapeView.style._resolvePaint(in: environment.value)
            let path = shape.value.path(in: CGRect(origin: .zero, size: size))
            var gradient: ResolvedGradient?
            var color: Color.Resolved?
            switch paint {
            case .color(let c): color = c
            case .gradient(let g): gradient = g
            }
            if let stroke = shapeView.stroke {
                return .shape(ResolvedShape(path: path, fill: nil, stroke: color, lineWidth: stroke.lineWidth, gradient: gradient, strokeStyle: stroke, pathSize: size))
            }
            return .shape(ResolvedShape(path: path, fill: color, stroke: nil, lineWidth: 0, gradient: gradient, pathSize: size))
        }
        inputs.makePlatformNode(content: content)
        let tracer = inputs.tracer
        let path = inputs.path
        let layoutShape = Attribute<S>(inputs.subgraph) { view.attribute.value.shape }
        let layout = inputs.makeLayoutAttribute { ShapeLayoutComputer(shape: layoutShape.value, path: path, tracer: tracer) }
        return _ViewOutputs(layout: layout)
    }
}

final class ShapeLayoutComputer<S: Shape>: LayoutComputer {
    let shape: S
    init(shape: S, path: ViewPath, tracer: UpdateTracer) {
        self.shape = shape
        super.init(path: path, tracer: tracer)
    }

    override func computeSize(_ proposal: ProposedViewSize) -> CGSize { shape.sizeThatFits(proposal) }

    override func isEquivalent(to other: LayoutComputer) -> Bool {
        guard let other = other as? ShapeLayoutComputer<S> else { return false }
        return GraphComparison.isIdentical(other.shape, shape)
    }
}

public struct Rectangle: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(rect) }
    public func inset(by amount: CGFloat) -> _InsetShape<Rectangle> { _InsetShape(base: self, inset: amount) }
}

public struct RoundedRectangle: InsettableShape {
    public var cornerSize: CGSize
    public var style: RoundedCornerStyle
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
        self.style = style
    }
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        self.cornerSize = cornerSize
        self.style = style
    }
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: cornerSize)
        return path
    }
    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(cornerSize.width, cornerSize.height) }
        set { cornerSize = CGSize(width: newValue.first, height: newValue.second) }
    }
    public func inset(by amount: CGFloat) -> _InsetShape<RoundedRectangle> { _InsetShape(base: self, inset: amount) }
}

public struct UnevenRoundedRectangle: Shape {
    public var cornerRadii: RectangleCornerRadii
    public init(cornerRadii: RectangleCornerRadii, style: RoundedCornerStyle = .continuous) { self.cornerRadii = cornerRadii }
    public init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0, topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) {
        cornerRadii = RectangleCornerRadii(topLeading: topLeadingRadius, bottomLeading: bottomLeadingRadius, bottomTrailing: bottomTrailingRadius, topTrailing: topTrailingRadius)
    }
    public func path(in rect: CGRect) -> Path {
        let r = cornerRadii
        let k: CGFloat = 0.5523
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r.topLeading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r.topTrailing, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r.topTrailing), control1: CGPoint(x: rect.maxX - r.topTrailing * (1 - k), y: rect.minY), control2: CGPoint(x: rect.maxX, y: rect.minY + r.topTrailing * (1 - k)))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r.bottomTrailing))
        path.addCurve(to: CGPoint(x: rect.maxX - r.bottomTrailing, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.maxY - r.bottomTrailing * (1 - k)), control2: CGPoint(x: rect.maxX - r.bottomTrailing * (1 - k), y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r.bottomLeading, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r.bottomLeading), control1: CGPoint(x: rect.minX + r.bottomLeading * (1 - k), y: rect.maxY), control2: CGPoint(x: rect.minX, y: rect.maxY - r.bottomLeading * (1 - k)))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r.topLeading))
        path.addCurve(to: CGPoint(x: rect.minX + r.topLeading, y: rect.minY), control1: CGPoint(x: rect.minX, y: rect.minY + r.topLeading * (1 - k)), control2: CGPoint(x: rect.minX + r.topLeading * (1 - k), y: rect.minY))
        path.closeSubpath()
        return path
    }
}

public struct RectangleCornerRadii: Hashable, Sendable {
    public var topLeading, bottomLeading, bottomTrailing, topTrailing: CGFloat
    public init(topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0, topTrailing: CGFloat = 0) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
}

public enum RoundedCornerStyle: Hashable, Sendable { case circular, continuous }

public struct Capsule: InsettableShape {
    public init(style: RoundedCornerStyle = .continuous) {}
    public func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path(roundedRect: rect, cornerRadius: radius)
    }
    public func inset(by amount: CGFloat) -> _InsetShape<Capsule> { _InsetShape(base: self, inset: amount) }
}

public struct Circle: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return Path(ellipseIn: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
    }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let size = proposal.replacingUnspecifiedDimensions()
        let side = min(size.width, size.height)
        return CGSize(width: side, height: side)
    }
    public func inset(by amount: CGFloat) -> _InsetShape<Circle> { _InsetShape(base: self, inset: amount) }
}

public struct Ellipse: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(ellipseIn: rect) }
    public func inset(by amount: CGFloat) -> _InsetShape<Ellipse> { _InsetShape(base: self, inset: amount) }
}

public struct ContainerRelativeShape: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: 8) }
    public func inset(by amount: CGFloat) -> _InsetShape<ContainerRelativeShape> { _InsetShape(base: self, inset: amount) }
}

// MARK: - Filled shape + stroke (`fill(...).stroke(...)`, macOS 14)

extension _ShapeView {
    public func stroke<S2: ShapeStyle>(_ content: S2, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        overlay { shape.stroke(content, lineWidth: lineWidth) }
    }

    public func stroke<S2: ShapeStyle>(_ content: S2, style strokeStyle: StrokeStyle, antialiased: Bool = true) -> some View {
        overlay { shape.stroke(content, style: strokeStyle) }
    }

    public func strokeBorder<S2: ShapeStyle>(_ content: S2 = .foreground, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        overlay { shape.strokeBorder(content, lineWidth: lineWidth) }
    }

    public func strokeBorder<S2: ShapeStyle>(_ content: S2 = .foreground, style strokeStyle: StrokeStyle, antialiased: Bool = true) -> some View {
        overlay { shape.strokeBorder(content, style: strokeStyle) }
    }
}
