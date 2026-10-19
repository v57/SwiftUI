// Types SwiftUI's API uses that come from CoreGraphics on Apple platforms but are missing from
// swift-corelibs-foundation (which only has CGFloat, CGPoint, CGSize, CGRect). Built on non-Apple
// platforms only; _SwiftUICore re-exports this module there.
#if !canImport(CoreGraphics)
import Foundation

public struct CGAffineTransform: Hashable, Sendable, Codable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public init(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) {
        self.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    public init(translationX tx: CGFloat, y ty: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty) }
    public init(scaleX sx: CGFloat, y sy: CGFloat) { self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    public init(rotationAngle angle: CGFloat) {
        let cosine = CGFloat(cos(Double(angle))), sine = CGFloat(sin(Double(angle)))
        self.init(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    public static let identity = CGAffineTransform()
    public var isIdentity: Bool { self == .identity }

    /// `self` followed by `t2`.
    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: a * t2.a + b * t2.c, b: a * t2.b + b * t2.d,
                          c: c * t2.a + d * t2.c, d: c * t2.b + d * t2.d,
                          tx: tx * t2.a + ty * t2.c + t2.tx, ty: tx * t2.b + ty * t2.d + t2.ty)
    }

    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).concatenating(self)
    }

    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: x, y: y).concatenating(self)
    }

    public func rotated(by angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle).concatenating(self)
    }

    public func inverted() -> CGAffineTransform {
        let determinant = a * d - b * c
        guard determinant != 0 else { return self }
        return CGAffineTransform(a: d / determinant, b: -b / determinant, c: -c / determinant, d: a / determinant,
                                 tx: (c * ty - d * tx) / determinant, ty: (b * tx - a * ty) / determinant)
    }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

extension CGSize {
    public func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

extension CGRect {
    /// The bounding box of the transformed rectangle.
    public func applying(_ t: CGAffineTransform) -> CGRect {
        if t.isIdentity { return self }
        let corners = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)].map { $0.applying(t) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

public struct CGVector: Hashable, Sendable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init() { dx = 0; dy = 0 }
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public init(dx: Double, dy: Double) { self.dx = CGFloat(dx); self.dy = CGFloat(dy) }
    public static let zero = CGVector()
}
#endif
