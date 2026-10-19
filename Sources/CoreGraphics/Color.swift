import Foundation

/// A color space: RGB or gray by name (sRGB, Display P3, ...). Colors are drawn as sRGB values; the name is kept.
public final class CGColorSpace: @unchecked Sendable, Hashable {
    public enum Model: Int32, Sendable { case unknown = -1, monochrome, rgb, cmyk, lab, deviceN, indexed, pattern, XYZ }

    public static let sRGB = "kCGColorSpaceSRGB"
    public static let extendedSRGB = "kCGColorSpaceExtendedSRGB"
    public static let linearSRGB = "kCGColorSpaceLinearSRGB"
    public static let extendedLinearSRGB = "kCGColorSpaceExtendedLinearSRGB"
    public static let displayP3 = "kCGColorSpaceDisplayP3"
    public static let genericRGBLinear = "kCGColorSpaceGenericRGBLinear"
    public static let genericGrayGamma2_2 = "kCGColorSpaceGenericGrayGamma2_2"
    public static let extendedGray = "kCGColorSpaceExtendedGray"
    public static let linearGray = "kCGColorSpaceLinearGray"
    public static let deviceRGB = "kCGColorSpaceDeviceRGB"
    public static let deviceGray = "kCGColorSpaceDeviceGray"

    public let name: String?
    public let model: Model

    public init?(name: String) {
        switch name {
        case Self.genericGrayGamma2_2, Self.extendedGray, Self.linearGray, Self.deviceGray: model = .monochrome
        case Self.sRGB, Self.extendedSRGB, Self.linearSRGB, Self.extendedLinearSRGB, Self.displayP3, Self.genericRGBLinear,
            Self.deviceRGB:
            model = .rgb
        default: return nil
        }
        self.name = name
    }

    public var numberOfComponents: Int { model == .monochrome ? 1 : 3 }

    public static func == (lhs: CGColorSpace, rhs: CGColorSpace) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(name: CGColorSpace.deviceRGB)! }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(name: CGColorSpace.deviceGray)! }

/// A color: components in its color space plus alpha.
public final class CGColor: @unchecked Sendable, Hashable {
    public let colorSpace: CGColorSpace?
    /// The color space's components followed by alpha.
    public let components: [CGFloat]?

    public init?(colorSpace: CGColorSpace, components: UnsafePointer<CGFloat>) {
        self.colorSpace = colorSpace
        self.components = Array(UnsafeBufferPointer(start: components, count: colorSpace.numberOfComponents + 1))
    }

    /// Swift array spelling (Apple's takes a pointer; arrays convert implicitly there).
    public init?(colorSpace: CGColorSpace, components: [CGFloat]) {
        guard components.count == colorSpace.numberOfComponents + 1 else { return nil }
        self.colorSpace = colorSpace
        self.components = components
    }

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        components = [red, green, blue, alpha]
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public init(gray: CGFloat, alpha: CGFloat) {
        colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        components = [gray, alpha]
    }

    public static let black = CGColor(gray: 0, alpha: 1)
    public static let white = CGColor(gray: 1, alpha: 1)
    public static let clear = CGColor(gray: 0, alpha: 0)

    public var numberOfComponents: Int { components?.count ?? 0 }
    public var alpha: CGFloat { components?.last ?? 1 }

    public func copy(alpha: CGFloat) -> CGColor? {
        guard let colorSpace, var components else { return nil }
        components[components.count - 1] = alpha
        return CGColor(colorSpace: colorSpace, components: components)
    }

    /// Straight (not premultiplied) sRGB components, 0...1.
    public var _rgba: (r: Double, g: Double, b: Double, a: Double) {
        guard let c = components, !c.isEmpty else { return (0, 0, 0, 0) }
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        if c.count >= 4 { return (clamp(c[0]), clamp(c[1]), clamp(c[2]), clamp(c[3])) }
        if c.count == 2 { return (clamp(c[0]), clamp(c[0]), clamp(c[0]), clamp(c[1])) }
        return (clamp(c[0]), clamp(c[0]), clamp(c[0]), 1)
    }

    public static func == (lhs: CGColor, rhs: CGColor) -> Bool {
        lhs.components == rhs.components && lhs.colorSpace == rhs.colorSpace
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(components) }
}

/// Colors at locations along a gradient's axis.
public final class CGGradient: @unchecked Sendable {
    public struct DrawingOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let drawsBeforeStartLocation = DrawingOptions(rawValue: 1)
        public static let drawsAfterEndLocation = DrawingOptions(rawValue: 2)
    }

    let stops: [(location: Double, color: (r: Double, g: Double, b: Double, a: Double))]

    /// `colors` holds `CGColor`s (Apple's takes a CFArray).
    public init?(colorsSpace space: CGColorSpace?, colors: [Any], locations: [CGFloat]?) {
        guard let stops = Self.stops(colors, locations?.map(Double.init)) else { return nil }
        self.stops = stops
    }

    private static func stops(_ colors: [Any], _ locations: [Double]?) -> [(location: Double, color: (r: Double, g: Double, b: Double, a: Double))]? {
        let colors = colors.compactMap { $0 as? CGColor }
        guard !colors.isEmpty else { return nil }
        let locations = locations ?? colors.indices.map { colors.count == 1 ? 0 : Double($0) / Double(colors.count - 1) }
        return zip(locations, colors.map(\._rgba)).map { (location: $0, color: $1) }.sorted { $0.location < $1.location }
    }

    /// The premultiplied color at `t` (0...1 along the axis).
    func color(at t: Double) -> (Double, Double, Double, Double) {
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        var c = first.color
        if t <= first.location {
            c = first.color
        } else if t >= last.location {
            c = last.color
        } else {
            for index in 1..<stops.count where t <= stops[index].location {
                let a = stops[index - 1], b = stops[index]
                let f = b.location > a.location ? (t - a.location) / (b.location - a.location) : 0
                c = (a.color.r + (b.color.r - a.color.r) * f, a.color.g + (b.color.g - a.color.g) * f,
                     a.color.b + (b.color.b - a.color.b) * f, a.color.a + (b.color.a - a.color.a) * f)
                break
            }
        }
        return (c.r * c.a, c.g * c.a, c.b * c.a, c.a)
    }
}
