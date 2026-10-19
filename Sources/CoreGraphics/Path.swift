import Foundation

public enum CGPathElementType: Int32, Sendable {
    case moveToPoint, addLineToPoint, addQuadCurveToPoint, addCurveToPoint, closeSubpath
}

/// One element of a path, as `applyWithBlock` passes it: its points (control points first, then the end point).
public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>
}

public enum CGPathFillRule: Int, Sendable { case winding, evenOdd }

public enum CGPathDrawingMode: Int32, Sendable { case fill, eoFill, stroke, fillStroke, eoFillStroke }

/// An immutable path: moves, lines, quadratic and cubic curves.
public class CGPath: @unchecked Sendable, Equatable {
    enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    var elements: [Element]

    init(elements: [Element]) { self.elements = elements }

    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let path = CGMutablePath()
        path.addRect(rect, transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let path = CGMutablePath()
        path.addEllipse(in: rect, transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    public convenience init(roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: UnsafePointer<CGAffineTransform>?) {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    public var isEmpty: Bool { elements.isEmpty }

    public var currentPoint: CGPoint {
        var start = CGPoint.zero, current = CGPoint.zero
        for element in elements {
            switch element {
            case .move(let p): start = p; current = p
            case .line(let p), .quad(let p, _), .cubic(let p, _, _): current = p
            case .close: current = start
            }
        }
        return current
    }

    /// The smallest rectangle holding every point, control points included.
    public var boundingBox: CGRect {
        var points: [CGPoint] = []
        for element in elements {
            switch element {
            case .move(let p), .line(let p): points.append(p)
            case let .quad(p, c): points += [p, c]
            case let .cubic(p, c1, c2): points += [p, c1, c2]
            case .close: break
            }
        }
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The bounding box of the flattened path (curves' extremes, not their control points).
    public var boundingBoxOfPath: CGRect {
        let points = _flattened(tolerance: 0.1).flatMap { $0.points }
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func applyWithBlock(_ block: (UnsafePointer<CGPathElement>) -> Void) {
        let points = UnsafeMutablePointer<CGPoint>.allocate(capacity: 3)
        defer { points.deallocate() }
        for element in elements {
            var type: CGPathElementType
            switch element {
            case .move(let p): type = .moveToPoint; points[0] = p
            case .line(let p): type = .addLineToPoint; points[0] = p
            case let .quad(p, c): type = .addQuadCurveToPoint; points[0] = c; points[1] = p
            case let .cubic(p, c1, c2): type = .addCurveToPoint; points[0] = c1; points[1] = c2; points[2] = p
            case .close: type = .closeSubpath
            }
            var element = CGPathElement(type: type, points: points)
            withUnsafePointer(to: &element) { block($0) }
        }
    }

    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        CGPath(elements: transformed(transform?.pointee ?? .identity))
    }

    public func copy(dashingWithPhase phase: CGFloat, lengths: [CGFloat], transform: CGAffineTransform = .identity) -> CGPath {
        CGPath(elements: transformed(transform))
    }

    public func mutableCopy() -> CGMutablePath? { CGMutablePath(elements: elements) }

    public func contains(_ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity) -> Bool {
        var winding = 0
        for polygon in CGPath(elements: transformed(transform))._flattened(tolerance: 0.1) {
            let points = polygon.points
            guard points.count > 1 else { continue }
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                if a.y <= point.y {
                    if b.y > point.y, (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
                } else if b.y <= point.y, (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1
                }
            }
        }
        return rule == .winding ? winding != 0 : winding % 2 != 0
    }

    func transformed(_ t: CGAffineTransform) -> [Element] {
        if t.isIdentity { return elements }
        return elements.map { element in
            switch element {
            case .move(let p): .move(p.applying(t))
            case .line(let p): .line(p.applying(t))
            case let .quad(p, c): .quad(p.applying(t), control: c.applying(t))
            case let .cubic(p, c1, c2): .cubic(p.applying(t), control1: c1.applying(t), control2: c2.applying(t))
            case .close: .close
            }
        }
    }

    /// The subpaths as polylines (curves split until within `tolerance`), each with whether it was closed.
    public func _flattened(tolerance: CGFloat) -> [(points: [CGPoint], closed: Bool)] {
        var result: [(points: [CGPoint], closed: Bool)] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func finish(closed: Bool) {
            if current.count > 1 || (closed && !current.isEmpty) { result.append((current, closed)) }
            current = []
        }
        for element in elements {
            switch element {
            case .move(let p):
                finish(closed: false)
                current = [p]; start = p
            case .line(let p):
                if current.isEmpty { current = [start] }
                current.append(p)
            case let .quad(p, c):
                if current.isEmpty { current = [start] }
                let p0 = current.last!
                let steps = Self.steps(length: hypot(c.x - p0.x, c.y - p0.y) + hypot(p.x - c.x, p.y - c.y), tolerance: tolerance)
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    current.append(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p.y))
                }
            case let .cubic(p, c1, c2):
                if current.isEmpty { current = [start] }
                let p0 = current.last!
                let length = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p.x - c2.x, p.y - c2.y)
                let steps = Self.steps(length: length, tolerance: tolerance)
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p.x, y: a * p0.y + b * c1.y + c * c2.y + d * p.y))
                }
            case .close:
                finish(closed: true)
                current = []
            }
        }
        finish(closed: false)
        return result
    }

    private static func steps(length: CGFloat, tolerance: CGFloat) -> Int {
        guard length.isFinite else { return 1 }
        return max(1, min(256, Int((length / max(tolerance, 0.01)).squareRoot().rounded(.up))))
    }

    public static func == (lhs: CGPath, rhs: CGPath) -> Bool { lhs.elements == rhs.elements }
}

/// A path you build up.
public final class CGMutablePath: CGPath, @unchecked Sendable {
    public init() { super.init(elements: []) }
    override init(elements: [Element]) { super.init(elements: elements) }

    private var lastMove = CGPoint.zero

    public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
        let p = point.applying(transform)
        elements.append(.move(p)); lastMove = p
    }

    public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
        if elements.isEmpty { move(to: point, transform: transform); return }
        elements.append(.line(point.applying(transform)))
    }

    public func addLines(between points: [CGPoint], transform: CGAffineTransform = .identity) {
        guard let first = points.first else { return }
        move(to: first, transform: transform)
        for point in points.dropFirst() { addLine(to: point, transform: transform) }
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        if elements.isEmpty { move(to: control, transform: transform) }
        elements.append(.quad(end.applying(transform), control: control.applying(transform)))
    }

    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint, transform: CGAffineTransform = .identity) {
        if elements.isEmpty { move(to: control1, transform: transform) }
        elements.append(.cubic(end.applying(transform), control1: control1.applying(transform), control2: control2.applying(transform)))
    }

    public func closeSubpath() {
        guard !elements.isEmpty else { return }
        elements.append(.close)
    }

    public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        move(to: CGPoint(x: r.minX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY), transform: transform)
        addLine(to: CGPoint(x: r.minX, y: r.maxY), transform: transform)
        closeSubpath()
    }

    public func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }

    public func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let k: CGFloat = 0.5522847498
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        move(to: CGPoint(x: cx + rx, y: cy), transform: transform)
        addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ry * k), control2: CGPoint(x: cx + rx * k, y: cy + ry), transform: transform)
        addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - rx * k, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ry * k), transform: transform)
        addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ry * k), control2: CGPoint(x: cx - rx * k, y: cy - ry), transform: transform)
        addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + rx * k, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ry * k), transform: transform)
        closeSubpath()
    }

    public func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let w = min(cornerWidth, r.width / 2), h = min(cornerHeight, r.height / 2)
        guard w > 0, h > 0 else { addRect(r, transform: transform); return }
        let k: CGFloat = 0.5522847498
        move(to: CGPoint(x: r.minX + w, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX - w, y: r.minY), transform: transform)
        addCurve(to: CGPoint(x: r.maxX, y: r.minY + h), control1: CGPoint(x: r.maxX - w + w * k, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + h - h * k), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY - h), transform: transform)
        addCurve(to: CGPoint(x: r.maxX - w, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - h + h * k), control2: CGPoint(x: r.maxX - w + w * k, y: r.maxY), transform: transform)
        addLine(to: CGPoint(x: r.minX + w, y: r.maxY), transform: transform)
        addCurve(to: CGPoint(x: r.minX, y: r.maxY - h), control1: CGPoint(x: r.minX + w - w * k, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - h + h * k), transform: transform)
        addLine(to: CGPoint(x: r.minX, y: r.minY + h), transform: transform)
        addCurve(to: CGPoint(x: r.minX + w, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + h - h * k), control2: CGPoint(x: r.minX + w - w * k, y: r.minY), transform: transform)
        closeSubpath()
    }

    /// An arc around `center` (angles in radians, counter-clockwise when `clockwise` is false in a y-up space).
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool, transform: CGAffineTransform = .identity) {
        var sweep = endAngle - startAngle
        let full = 2 * CGFloat.pi
        if clockwise { while sweep > 0 { sweep -= full } } else { while sweep < 0 { sweep += full } }
        let start = CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle))
        if elements.isEmpty { move(to: start, transform: transform) } else { addLine(to: start, transform: transform) }
        let segments = max(1, Int((abs(sweep) / (CGFloat.pi / 2)).rounded(.up)))
        let step = sweep / CGFloat(segments)
        var angle = startAngle
        for _ in 0..<segments {
            let next = angle + step
            let k = 4 / 3 * tan(step / 4)
            let p1 = CGPoint(x: center.x + radius * (cos(angle) - k * sin(angle)), y: center.y + radius * (sin(angle) + k * cos(angle)))
            let p2 = CGPoint(x: center.x + radius * (cos(next) + k * sin(next)), y: center.y + radius * (sin(next) - k * cos(next)))
            let p3 = CGPoint(x: center.x + radius * cos(next), y: center.y + radius * sin(next))
            addCurve(to: p3, control1: p1, control2: p2, transform: transform)
            angle = next
        }
    }

    public func addRelativeArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, delta: CGFloat, transform: CGAffineTransform = .identity) {
        addArc(center: center, radius: radius, startAngle: startAngle, endAngle: startAngle + delta, clockwise: delta < 0, transform: transform)
    }

    public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        elements += path.transformed(transform)
    }
}
