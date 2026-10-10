import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreGraphics)
extension Path {
    /// The path as a Core Graphics path.
    public var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case let .quadCurve(p, c): path.addQuadCurve(to: p, control: c)
            case let .curve(p, c1, c2): path.addCurve(to: p, control1: c1, control2: c2)
            case .closeSubpath: path.closeSubpath()
            }
        }
        return path
    }

    public init(_ path: CGPath) {
        self.init()
        var result = Path()
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: result.move(to: points[0])
            case .addLineToPoint: result.addLine(to: points[0])
            case .addQuadCurveToPoint: result.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint: result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath: result.closeSubpath()
            @unknown default: break
            }
        }
        self = result
    }

    // Boolean operations (macOS 14 Core Graphics; fill rule from `eoFill`).

    public func union(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.union(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }

    public func intersection(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.intersection(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }

    public func subtracting(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.subtracting(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }

    public func symmetricDifference(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.symmetricDifference(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }

    public func lineIntersection(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.lineIntersection(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }

    public func lineSubtraction(_ other: Path, eoFill: Bool = false) -> Path {
        Path(cgPath.lineSubtracting(other.cgPath, using: eoFill ? .evenOdd : .winding))
    }
}

/// A shape combining two shapes with a path operation.
public struct _ShapeOperation<A: Shape, B: Shape>: Shape {
    enum Operation { case union, intersection, subtracting, symmetricDifference, lineIntersection, lineSubtraction }
    let first: A
    let second: B
    let operation: Operation
    let eoFill: Bool

    public func path(in rect: CGRect) -> Path {
        let a = first.path(in: rect), b = second.path(in: rect)
        switch operation {
        case .union: return a.union(b, eoFill: eoFill)
        case .intersection: return a.intersection(b, eoFill: eoFill)
        case .subtracting: return a.subtracting(b, eoFill: eoFill)
        case .symmetricDifference: return a.symmetricDifference(b, eoFill: eoFill)
        case .lineIntersection: return a.lineIntersection(b, eoFill: eoFill)
        case .lineSubtraction: return a.lineSubtraction(b, eoFill: eoFill)
        }
    }
}

extension Shape {
    public func union<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .union, eoFill: eoFill) }
    public func intersection<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .intersection, eoFill: eoFill) }
    public func subtracting<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .subtracting, eoFill: eoFill) }
    public func symmetricDifference<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .symmetricDifference, eoFill: eoFill) }
    public func lineIntersection<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .lineIntersection, eoFill: eoFill) }
    public func lineSubtraction<T: Shape>(_ other: T, eoFill: Bool = false) -> some Shape { _ShapeOperation(first: self, second: other, operation: .lineSubtraction, eoFill: eoFill) }
}
#endif

// MARK: - Hierarchical lists

extension List where SelectionValue == Never {
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, children: KeyPath<Data.Element, Data?>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == OutlineGroup<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init { OutlineGroup(data, children: children, content: rowContent) }
    }
}

extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, children: KeyPath<Data.Element, Data?>, selection: Binding<Set<SelectionValue>>?, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == OutlineGroup<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: selection) { OutlineGroup(data, children: children, content: rowContent) }
    }

    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, children: KeyPath<Data.Element, Data?>, selection: Binding<SelectionValue?>?, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent) where Content == OutlineGroup<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: selection) { OutlineGroup(data, children: children, content: rowContent) }
    }
}
