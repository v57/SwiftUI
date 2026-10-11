import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The user's preferred text size. macOS always uses `.large`; other platforms' backends map
/// their system font scale to it, and text styles, `relativeTo:` custom fonts and
/// `@ScaledMetric` values scale with it.
public enum DynamicTypeSize: Hashable, Comparable, CaseIterable, Sendable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    public var isAccessibilitySize: Bool { self >= .accessibility1 }

    /// Scale relative to `.large` (from the body sizes 14 … 53 pt around 17 pt).
    public var _scale: CGFloat {
        switch self {
        case .xSmall: 14.0 / 17
        case .small: 15.0 / 17
        case .medium: 16.0 / 17
        case .large: 1
        case .xLarge: 19.0 / 17
        case .xxLarge: 21.0 / 17
        case .xxxLarge: 23.0 / 17
        case .accessibility1: 28.0 / 17
        case .accessibility2: 33.0 / 17
        case .accessibility3: 40.0 / 17
        case .accessibility4: 47.0 / 17
        case .accessibility5: 53.0 / 17
        }
    }

    /// The size for a platform font scale factor (1 = default).
    public init(fontScale: CGFloat) {
        self = DynamicTypeSize.allCases.min { abs($0._scale - fontScale) < abs($1._scale - fontScale) } ?? .large
    }
}

struct DynamicTypeSizeKey: EnvironmentKey { static let defaultValue = DynamicTypeSize.large }

extension EnvironmentValues {
    public var dynamicTypeSize: DynamicTypeSize {
        get { self[DynamicTypeSizeKey.self] }
        set { self[DynamicTypeSizeKey.self] = newValue }
    }
}

extension View {
    /// Sets the text size of the content.
    public func dynamicTypeSize(_ size: DynamicTypeSize) -> some View {
        environment(\.dynamicTypeSize, size)
    }

    /// Limits the text size of the content to a range.
    public func dynamicTypeSize<T: RangeExpression>(_ range: T) -> some View where T.Bound == DynamicTypeSize {
        transformEnvironment(\.dynamicTypeSize) { size in
            let all = DynamicTypeSize.allCases
            if !range.contains(size), let nearest = all.filter({ range.contains($0) }).min(by: {
                abs(all.firstIndex(of: $0)! - all.firstIndex(of: size)!) < abs(all.firstIndex(of: $1)! - all.firstIndex(of: size)!)
            }) {
                size = nearest
            }
        }
    }
}

/// A value that scales with the dynamic type size, like text of `textStyle`.
@propertyWrapper
public struct ScaledMetric<Value: BinaryFloatingPoint>: DynamicProperty {
    let base: Value
    let textStyle: Font.TextStyle
    @Environment(\.dynamicTypeSize) private var size

    public init(wrappedValue: Value, relativeTo textStyle: Font.TextStyle) {
        self.base = wrappedValue
        self.textStyle = textStyle
    }

    public init(wrappedValue: Value) {
        self.init(wrappedValue: wrappedValue, relativeTo: .body)
    }

    public var wrappedValue: Value { base * Value(size._scale) }
}
