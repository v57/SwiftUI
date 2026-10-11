import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

// MARK: - ProjectionTransform

/// A 3×3 projective transform of the plane (row-vector convention, like `CGAffineTransform`).
public struct ProjectionTransform: Hashable, Sendable {
    public var m11: CGFloat = 1, m12: CGFloat = 0, m13: CGFloat = 0
    public var m21: CGFloat = 0, m22: CGFloat = 1, m23: CGFloat = 0
    public var m31: CGFloat = 0, m32: CGFloat = 0, m33: CGFloat = 1

    public init() {}

    public init(_ m: CGAffineTransform) {
        m11 = m.a; m12 = m.b
        m21 = m.c; m22 = m.d
        m31 = m.tx; m32 = m.ty
    }

    #if canImport(QuartzCore)
    /// The transform of the z = 0 plane (z input and output dropped).
    public init(_ m: CATransform3D) {
        m11 = m.m11; m12 = m.m12; m13 = m.m14
        m21 = m.m21; m22 = m.m22; m23 = m.m24
        m31 = m.m41; m32 = m.m42; m33 = m.m44
    }
    #endif

    public var isIdentity: Bool { self == ProjectionTransform() }
    public var isAffine: Bool { m13 == 0 && m23 == 0 && m33 == 1 }

    /// `self` followed by `rhs`.
    public func concatenating(_ rhs: ProjectionTransform) -> ProjectionTransform {
        var r = ProjectionTransform()
        r.m11 = m11 * rhs.m11 + m12 * rhs.m21 + m13 * rhs.m31
        r.m12 = m11 * rhs.m12 + m12 * rhs.m22 + m13 * rhs.m32
        r.m13 = m11 * rhs.m13 + m12 * rhs.m23 + m13 * rhs.m33
        r.m21 = m21 * rhs.m11 + m22 * rhs.m21 + m23 * rhs.m31
        r.m22 = m21 * rhs.m12 + m22 * rhs.m22 + m23 * rhs.m32
        r.m23 = m21 * rhs.m13 + m22 * rhs.m23 + m23 * rhs.m33
        r.m31 = m31 * rhs.m11 + m32 * rhs.m21 + m33 * rhs.m31
        r.m32 = m31 * rhs.m12 + m32 * rhs.m22 + m33 * rhs.m32
        r.m33 = m31 * rhs.m13 + m32 * rhs.m23 + m33 * rhs.m33
        return r
    }

    private var determinant: CGFloat {
        m11 * (m22 * m33 - m23 * m32) - m12 * (m21 * m33 - m23 * m31) + m13 * (m21 * m32 - m22 * m31)
    }

    @discardableResult
    public mutating func invert() -> Bool {
        let det = determinant
        guard det != 0 else { return false }
        let inv = 1 / det
        self = ProjectionTransform(
            m11: (m22 * m33 - m23 * m32) * inv, m12: (m13 * m32 - m12 * m33) * inv, m13: (m12 * m23 - m13 * m22) * inv,
            m21: (m23 * m31 - m21 * m33) * inv, m22: (m11 * m33 - m13 * m31) * inv, m23: (m13 * m21 - m11 * m23) * inv,
            m31: (m21 * m32 - m22 * m31) * inv, m32: (m12 * m31 - m11 * m32) * inv, m33: (m11 * m22 - m12 * m21) * inv)
        return true
    }

    public func inverted() -> ProjectionTransform {
        var copy = self
        copy.invert()
        return copy
    }

    /// Maps a point (with the perspective divide).
    public func apply(to point: CGPoint) -> CGPoint {
        let w = point.x * m13 + point.y * m23 + m33
        return CGPoint(x: (point.x * m11 + point.y * m21 + m31) / w, y: (point.x * m12 + point.y * m22 + m32) / w)
    }

    init(m11: CGFloat, m12: CGFloat, m13: CGFloat, m21: CGFloat, m22: CGFloat, m23: CGFloat, m31: CGFloat, m32: CGFloat, m33: CGFloat) {
        (self.m11, self.m12, self.m13) = (m11, m12, m13)
        (self.m21, self.m22, self.m23) = (m21, m22, m23)
        (self.m31, self.m32, self.m33) = (m31, m32, m33)
    }

    static func translation(_ x: CGFloat, _ y: CGFloat) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }

    static func interpolate(_ a: ProjectionTransform, _ b: ProjectionTransform, _ t: Double) -> ProjectionTransform {
        let t = CGFloat(t)
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return ProjectionTransform(m11: l(a.m11, b.m11), m12: l(a.m12, b.m12), m13: l(a.m13, b.m13),
                                   m21: l(a.m21, b.m21), m22: l(a.m22, b.m22), m23: l(a.m23, b.m23),
                                   m31: l(a.m31, b.m31), m32: l(a.m32, b.m32), m33: l(a.m33, b.m33))
    }
}

/// 4×4 matrix in Core Animation's row-vector convention (used to build 3D rotations without
/// QuartzCore, so it also works on other platforms).
struct _Matrix4: Equatable {
    var m: [CGFloat] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    subscript(row: Int, column: Int) -> CGFloat {
        get { m[(row - 1) * 4 + (column - 1)] }
        set { m[(row - 1) * 4 + (column - 1)] = newValue }
    }

    static func translation(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> _Matrix4 {
        var r = _Matrix4()
        r[4, 1] = x; r[4, 2] = y; r[4, 3] = z
        return r
    }

    /// Same matrix as `CATransform3DMakeRotation(angle, x, y, z)`.
    static func rotation(_ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> _Matrix4 {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 0 else { return _Matrix4() }
        let (x, y, z) = (x / length, y / length, z / length)
        let c = cos(angle), s = sin(angle), t = 1 - c
        var r = _Matrix4()
        r[1, 1] = t * x * x + c; r[1, 2] = t * x * y + z * s; r[1, 3] = t * x * z - y * s
        r[2, 1] = t * x * y - z * s; r[2, 2] = t * y * y + c; r[2, 3] = t * y * z + x * s
        r[3, 1] = t * x * z + y * s; r[3, 2] = t * y * z - x * s; r[3, 3] = t * z * z + c
        return r
    }

    /// `self` followed by `rhs`.
    func concatenating(_ rhs: _Matrix4) -> _Matrix4 {
        var r = _Matrix4()
        for i in 1...4 {
            for j in 1...4 {
                var sum: CGFloat = 0
                for k in 1...4 { sum += self[i, k] * rhs[k, j] }
                r[i, j] = sum
            }
        }
        return r
    }

    /// The transform of the z = 0 plane.
    var projection: ProjectionTransform {
        ProjectionTransform(m11: self[1, 1], m12: self[1, 2], m13: self[1, 4],
                            m21: self[2, 1], m22: self[2, 2], m23: self[2, 4],
                            m31: self[4, 1], m32: self[4, 2], m33: self[4, 4])
    }
}

// MARK: - GeometryEffect

/// An effect that transforms the drawing of the view (not its layout) with a projection that
/// depends on the view's size. Animatable effects animate through their `animatableData`.
public protocol GeometryEffect: Animatable, ViewModifier where Body == Never {
    func effectValue(size: CGSize) -> ProjectionTransform
    static var _affectsLayout: Bool { get }
}

extension GeometryEffect {
    public static var _affectsLayout: Bool { true }

    public func ignoredByLayout() -> _IgnoredByLayoutEffect<Self> { _IgnoredByLayoutEffect(base: self) }

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        let inputs = inputs.with(path: "geometryEffect")
        let effect = animatedIfNeeded(modifier.attribute, host: inputs.host, scope: inputs.animationScope, subgraph: inputs.subgraph)
        let geometry = inputs.geometry
        let content = Attribute<RenderContent>(inputs.subgraph, isEqual: { $0 == $1 }) {
            // Geometry may be unbound while the graph is built.
            .effect(.projection(effect.value.effectValue(size: geometry.valueIfPresent?.size ?? .zero)))
        }
        let render = inputs.makePlatformNode(content: content, actions: RenderActions())
        var childInputs = inputs
        childInputs.render = render
        return body(childInputs)
    }
}

public struct _IgnoredByLayoutEffect<Base: GeometryEffect>: GeometryEffect {
    public var base: Base
    public static var _affectsLayout: Bool { false }
    public var animatableData: Base.AnimatableData {
        get { base.animatableData }
        set { base.animatableData = newValue }
    }
    public func effectValue(size: CGSize) -> ProjectionTransform { base.effectValue(size: size) }
}

public struct _ProjectionEffect: GeometryEffect {
    public var transform: ProjectionTransform
    public init(transform: ProjectionTransform) { self.transform = transform }
    public func effectValue(size: CGSize) -> ProjectionTransform { transform }
}

public struct _AffineTransformEffect: GeometryEffect {
    public var transform: CGAffineTransform
    public init(transform: CGAffineTransform) { self.transform = transform }
    public func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(transform) }
}

/// `rotation3DEffect`: rotation about an axis through the anchor, with perspective.
public struct _Rotation3DEffect: GeometryEffect {
    public var angle: Angle
    public var axis: (x: CGFloat, y: CGFloat, z: CGFloat)
    public var anchor: UnitPoint
    public var anchorZ: CGFloat
    public var perspective: CGFloat

    public init(angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat), anchor: UnitPoint = .center, anchorZ: CGFloat = 0, perspective: CGFloat = 1) {
        self.angle = angle
        self.axis = axis
        self.anchor = anchor
        self.anchorZ = anchorZ
        self.perspective = perspective
    }

    public var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(angle.radians, AnimatablePair(anchorZ, perspective)) }
        set {
            angle = .radians(newValue.first)
            anchorZ = newValue.second.first
            perspective = newValue.second.second
        }
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        let ax = anchor.x * size.width, ay = anchor.y * size.height
        var perspectiveMatrix = _Matrix4()
        let scale = max(size.width, size.height)
        perspectiveMatrix[3, 4] = scale > 0 ? -perspective / scale : 0
        let matrix = _Matrix4.translation(-ax, -ay, -anchorZ)
            .concatenating(.rotation(CGFloat(angle.radians), axis.x, axis.y, axis.z))
            .concatenating(perspectiveMatrix)
            .concatenating(.translation(ax, ay, anchorZ))
        return matrix.projection
    }
}

extension _Rotation3DEffect: @MainActor Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.angle == b.angle && a.axis == b.axis && a.anchor == b.anchor && a.anchorZ == b.anchorZ && a.perspective == b.perspective
    }
}

extension View {
    public func projectionEffect(_ transform: ProjectionTransform) -> some View {
        modifier(_ProjectionEffect(transform: transform))
    }

    public func transformEffect(_ transform: CGAffineTransform) -> some View {
        modifier(_AffineTransformEffect(transform: transform))
    }

    public func rotation3DEffect(_ angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat), anchor: UnitPoint = .center, anchorZ: CGFloat = 0, perspective: CGFloat = 1) -> some View {
        modifier(_Rotation3DEffect(angle: angle, axis: axis, anchor: anchor, anchorZ: anchorZ, perspective: perspective))
    }

    /// Isolates the view's geometry from its parent's animations (subviews animate from their
    /// own previous frames, which is how this renderer already animates).
    public func geometryGroup() -> some View { self }
}
