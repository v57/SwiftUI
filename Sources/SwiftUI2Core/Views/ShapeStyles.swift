import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Gradients

public struct ResolvedGradient: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case linear(start: UnitPoint, end: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        case angular(center: UnitPoint, startAngle: Double, endAngle: Double)
        case elliptical(center: UnitPoint, startFraction: CGFloat, endFraction: CGFloat)
    }

    public struct Stop: Hashable, Sendable {
        public var color: Color.Resolved
        public var location: CGFloat
    }

    public var kind: Kind
    public var stops: [Stop]

    /// The average color, used where gradients can't be drawn (text).
    var averageColor: Color.Resolved {
        guard !stops.isEmpty else { return Color.Resolved(red: 0, green: 0, blue: 0, opacity: 0) }
        let count = Float(stops.count)
        return Color.Resolved(
            red: stops.map(\.color.red).reduce(0, +) / count,
            green: stops.map(\.color.green).reduce(0, +) / count,
            blue: stops.map(\.color.blue).reduce(0, +) / count,
            opacity: stops.map(\.color.opacity).reduce(0, +) / count
        )
    }
}

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: CGFloat
        public init(color: Color, location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) { self.stops = stops }

    public init(colors: [Color]) {
        let count = max(colors.count - 1, 1)
        stops = colors.enumerated().map { Stop(color: $1, location: CGFloat($0) / CGFloat(count)) }
    }

    func resolve(in environment: EnvironmentValues) -> [ResolvedGradient.Stop] {
        stops.map { ResolvedGradient.Stop(color: $0.color.resolve(in: environment), location: $0.location) }
    }
}

/// `Color.red.gradient`
public struct AnyGradient: Hashable, Sendable, ShapeStyle {
    let base: Color

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        let color = base.resolve(in: environment)
        var lighter = color
        lighter.red = min(1, color.red + 0.12)
        lighter.green = min(1, color.green + 0.12)
        lighter.blue = min(1, color.blue + 0.12)
        var darker = color
        darker.red = max(0, color.red - 0.08)
        darker.green = max(0, color.green - 0.08)
        darker.blue = max(0, color.blue - 0.08)
        return .gradient(ResolvedGradient(kind: .linear(start: .top, end: .bottom), stops: [
            .init(color: lighter, location: 0), .init(color: darker, location: 1),
        ]))
    }
}

extension Color {
    public var gradient: AnyGradient { AnyGradient(base: self) }
}

public struct LinearGradient: ShapeStyle {
    let gradient: Gradient
    let startPoint: UnitPoint
    let endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }

    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .gradient(ResolvedGradient(kind: .linear(start: startPoint, end: endPoint), stops: gradient.resolve(in: environment)))
    }
}

public struct RadialGradient: ShapeStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startRadius: CGFloat
    let endRadius: CGFloat

    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }

    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .gradient(ResolvedGradient(kind: .radial(center: center, startRadius: startRadius, endRadius: endRadius), stops: gradient.resolve(in: environment)))
    }
}

public struct AngularGradient: ShapeStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startAngle: Angle
    let endAngle: Angle

    public init(gradient: Gradient, center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = .degrees(360)) {
        self.gradient = gradient
        self.center = center
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    public init(colors: [Color], center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = .degrees(360)) {
        self.init(gradient: Gradient(colors: colors), center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .gradient(ResolvedGradient(kind: .angular(center: center, startAngle: startAngle.degrees, endAngle: endAngle.degrees), stops: gradient.resolve(in: environment)))
    }
}

public struct EllipticalGradient: ShapeStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startRadiusFraction: CGFloat
    let endRadiusFraction: CGFloat

    public init(gradient: Gradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) {
        self.gradient = gradient
        self.center = center
        self.startRadiusFraction = startRadiusFraction
        self.endRadiusFraction = endRadiusFraction
    }

    public init(colors: [Color], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .gradient(ResolvedGradient(kind: .elliptical(center: center, startFraction: startRadiusFraction, endFraction: endRadiusFraction), stops: gradient.resolve(in: environment)))
    }
}

/// Materials need platform blur, which is excluded; they resolve to translucent fills.
public struct Material: ShapeStyle, Hashable {
    let opacity: Float

    public static let ultraThinMaterial = Material(opacity: 0.35)
    public static let thinMaterial = Material(opacity: 0.5)
    public static let regularMaterial = Material(opacity: 0.7)
    public static let thickMaterial = Material(opacity: 0.85)
    public static let ultraThickMaterial = Material(opacity: 0.95)
    public static let bar = Material(opacity: 0.8)

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        .color(environment.colorScheme == .dark
            ? Color.Resolved(red: 0.17, green: 0.17, blue: 0.18, opacity: opacity)
            : Color.Resolved(red: 0.96, green: 0.96, blue: 0.97, opacity: opacity))
    }
}

extension ShapeStyle where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThinMaterial }
    public static var thinMaterial: Material { .thinMaterial }
    public static var regularMaterial: Material { .regularMaterial }
    public static var thickMaterial: Material { .thickMaterial }
    public static var ultraThickMaterial: Material { .ultraThickMaterial }
    public static var bar: Material { .bar }
}

extension ShapeStyle where Self == LinearGradient {
    public static func linearGradient(_ gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }
    public static func linearGradient(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
    }
}

extension ShapeStyle where Self == RadialGradient {
    public static func radialGradient(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(colors: colors, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

/// `style.opacity(0.5)` for any shape style.
public struct _OpacityShapeStyle<Base: ShapeStyle>: ShapeStyle {
    let base: Base
    let opacity: Double

    public func _resolvePaint(in environment: EnvironmentValues) -> ResolvedPaint {
        switch base._resolvePaint(in: environment) {
        case .color(var color):
            color.opacity *= Float(opacity)
            return .color(color)
        case .gradient(var gradient):
            gradient.stops = gradient.stops.map { var stop = $0; stop.color.opacity *= Float(opacity); return stop }
            return .gradient(gradient)
        }
    }
}

extension ShapeStyle {
    public func opacity(_ opacity: Double) -> _OpacityShapeStyle<Self> { _OpacityShapeStyle(base: self, opacity: opacity) }
}

// Gradients used directly as views fill their frame (like Color).
extension LinearGradient: View {
    public var body: some View { Rectangle().fill(self) }
}

extension RadialGradient: View {
    public var body: some View { Rectangle().fill(self) }
}

extension AngularGradient: View {
    public var body: some View { Rectangle().fill(self) }
}

extension EllipticalGradient: View {
    public var body: some View { Rectangle().fill(self) }
}

// MARK: - Stroke style

public struct StrokeStyle: Hashable, Sendable {
    public var lineWidth: CGFloat
    public var lineCap: LineCap
    public var lineJoin: LineJoin
    public var miterLimit: CGFloat
    public var dash: [CGFloat]
    public var dashPhase: CGFloat

    public enum LineCap: Hashable, Sendable { case butt, round, square }
    public enum LineJoin: Hashable, Sendable { case miter, round, bevel }

    public init(lineWidth: CGFloat = 1, lineCap: LineCap = .butt, lineJoin: LineJoin = .miter, miterLimit: CGFloat = 10, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }
}
