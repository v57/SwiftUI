import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Observation

@MainActor
private final class EnvironmentWriteCache<Value> {
    var parentHead: EnvironmentValues.Node?
    var value: Value?
    var result: EnvironmentValues?
}

/// Builds `parent + write(value)`, returning the previous result (same identity) when neither the
/// parent environment nor the written value changed — so descendants see no change at all.
@MainActor
func makeWritingEnvironment<Value>(
    parent: Attribute<EnvironmentValues>,
    subgraph: Subgraph,
    value: @escaping @MainActor () -> Value,
    write: @escaping (inout EnvironmentValues, Value) -> Void
) -> Attribute<EnvironmentValues> {
    let cache = EnvironmentWriteCache<Value>()
    return Attribute<EnvironmentValues>(subgraph) {
        let base = parent.value
        let newValue = value()
        if let result = cache.result, cache.parentHead === base.head, let old = cache.value, GraphComparison.isIdentical(old, newValue) {
            return result
        }
        var environment = base
        write(&environment, newValue)
        cache.parentHead = base.head
        cache.value = newValue
        cache.result = environment
        return environment
    }
}

/// A key path with the value to write there (compared field by field for cut-off).
struct _KeyedValue<Value> {
    let keyPath: WritableKeyPath<EnvironmentValues, Value>
    let value: Value
}

public struct _EnvironmentKeyWritingModifier<Value>: ViewModifier, EnvironmentModifier {
    public var keyPath: WritableKeyPath<EnvironmentValues, Value>
    public var value: Value

    public init(keyPath: WritableKeyPath<EnvironmentValues, Value>, value: Value) {
        self.keyPath = keyPath
        self.value = value
    }

    public typealias Body = Never

    // The modifier is only read in rules: its value may depend on layout (e.g. a font sized
    // from a GeometryReader proxy), which doesn't exist while the graph is being built.
    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues> {
        makeWritingEnvironment(parent: environment, subgraph: subgraph, value: { _KeyedValue(keyPath: modifier.value.keyPath, value: modifier.value.value) }) { environment, entry in
            environment[keyPath: entry.keyPath] = entry.value
        }
    }
}

public struct _EnvironmentTransformModifier<Value>: ViewModifier, EnvironmentModifier {
    let keyPath: WritableKeyPath<EnvironmentValues, Value>
    let transform: (inout Value) -> Void
    public typealias Body = Never

    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues> {
        makeWritingEnvironment(parent: environment, subgraph: subgraph, value: {
            let current = modifier.value
            var value = environment.value[keyPath: current.keyPath]
            current.transform(&value)
            return _KeyedValue(keyPath: current.keyPath, value: value)
        }) { environment, entry in
            environment[keyPath: entry.keyPath] = entry.value
        }
    }
}

struct _EnvironmentObjectModifier<Object: AnyObject>: ViewModifier, EnvironmentModifier {
    let object: Object?
    typealias Body = Never

    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues> {
        makeWritingEnvironment(parent: environment, subgraph: subgraph, value: { modifier.value.object }) { environment, object in
            environment[object: Object.self] = object
        }
    }
}

extension View {
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        modifier(_EnvironmentKeyWritingModifier(keyPath: keyPath, value: value))
    }

    public func transformEnvironment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, transform: @escaping (inout V) -> Void) -> some View {
        modifier(_EnvironmentTransformModifier(keyPath: keyPath, transform: transform))
    }

    /// Injects an `@Observable` object, read with `@Environment(Model.self)`.
    public func environment<T: AnyObject & Observable>(_ object: T?) -> some View {
        modifier(_EnvironmentObjectModifier(object: object))
    }

    /// Injects an `ObservableObject`, read with `@EnvironmentObject`.
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View {
        modifier(_EnvironmentObjectModifier(object: object))
    }

    public func font(_ font: Font?) -> some View {
        environment(\.font, font)
    }

    public func fontWeight(_ weight: Font.Weight?) -> some View {
        transformEnvironment(\.font) { font in font = (font ?? .body).weight(weight ?? .regular) }
    }

    public func bold(_ isActive: Bool = true) -> some View {
        transformEnvironment(\.font) { font in if isActive { font = (font ?? .body).bold() } }
    }

    public func italic(_ isActive: Bool = true) -> some View {
        transformEnvironment(\.font) { font in if isActive { font = (font ?? .body).italic() } }
    }

    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View {
        environment(\.foregroundStyle, AnyShapeStyle(style))
    }

    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some View {
        transformEnvironment(\.self) { environment in
            environment.foregroundStyle = AnyShapeStyle(primary)
            environment.foregroundStyleLevels = [AnyShapeStyle(primary), AnyShapeStyle(secondary)]
        }
    }

    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle, S3: ShapeStyle>(_ primary: S1, _ secondary: S2, _ tertiary: S3) -> some View {
        transformEnvironment(\.self) { environment in
            environment.foregroundStyle = AnyShapeStyle(primary)
            environment.foregroundStyleLevels = [AnyShapeStyle(primary), AnyShapeStyle(secondary), AnyShapeStyle(tertiary)]
        }
    }

    public func foregroundColor(_ color: Color?) -> some View {
        environment(\.foregroundStyle, color.map { AnyShapeStyle($0) })
    }

    public func tint(_ tint: Color?) -> some View {
        environment(\.tint, tint)
    }

    public func lineLimit(_ number: Int?) -> some View {
        environment(\.lineLimit, number)
    }

    public func lineLimit(_ limit: ClosedRange<Int>) -> some View {
        environment(\.lineLimit, limit.upperBound).environment(\.minimumLineLimit, limit.lowerBound)
    }

    public func lineLimit(_ limit: PartialRangeFrom<Int>) -> some View {
        environment(\.lineLimit, nil).environment(\.minimumLineLimit, limit.lowerBound)
    }

    public func lineLimit(_ limit: PartialRangeThrough<Int>) -> some View {
        environment(\.lineLimit, limit.upperBound).environment(\.minimumLineLimit, nil)
    }

    public func lineLimit(_ limit: Int, reservesSpace: Bool) -> some View {
        environment(\.lineLimit, limit).environment(\.minimumLineLimit, reservesSpace ? limit : nil)
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        environment(\.multilineTextAlignment, alignment)
    }

    public func disabled(_ disabled: Bool) -> some View {
        transformEnvironment(\.isEnabled) { enabled in enabled = enabled && !disabled }
    }

    public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        transformEnvironment(\.colorScheme) { scheme in if let colorScheme { scheme = colorScheme } }
    }
}

public enum TruncationMode: Sendable { case head, tail, middle }

extension View {
    public func truncationMode(_ mode: TruncationMode) -> some View { self }
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { self }
    public func lineSpacing(_ spacing: CGFloat) -> some View { self }
    public func kerning(_ kerning: CGFloat) -> some View { self }
    public func tracking(_ tracking: CGFloat) -> some View { self }
    public func textCase(_ textCase: Text.Case?) -> some View { self }
    public func textSelection<S: TextSelectability>(_ selectability: S) -> some View {
        environment(\.isTextSelectable, S.allowsSelection)
    }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> some View { self }
    public func symbolVariant(_ variant: SymbolVariants) -> some View { environment(\.symbolVariants, variant) }
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { self }
    public func edgesIgnoringSafeArea(_ edges: Edge.Set) -> some View { self }
    public func statusBarHidden(_ hidden: Bool = true) -> some View { self }
    public func persistentSystemOverlays(_ visibility: Visibility) -> some View { self }
}

public enum SymbolRenderingMode: Sendable { case monochrome, multicolor, hierarchical, palette }
struct SymbolVariantsKey: EnvironmentKey { static let defaultValue = SymbolVariants.none }

extension EnvironmentValues {
    public var symbolVariants: SymbolVariants {
        get { self[SymbolVariantsKey.self] }
        set { self[SymbolVariantsKey.self] = newValue }
    }
}

public struct SymbolVariants: Hashable, Sendable {
    let names: [String]
    public static let none = SymbolVariants(names: [])
    public static let fill = SymbolVariants(names: ["fill"])
    public static let circle = SymbolVariants(names: ["circle"])
    public static let square = SymbolVariants(names: ["square"])
    public static let rectangle = SymbolVariants(names: ["rectangle"])
    public static let slash = SymbolVariants(names: ["slash"])
    public var fill: SymbolVariants { SymbolVariants(names: names + ["fill"]) }
    public var circle: SymbolVariants { SymbolVariants(names: names + ["circle"]) }
    public var square: SymbolVariants { SymbolVariants(names: names + ["square"]) }
    public var rectangle: SymbolVariants { SymbolVariants(names: names + ["rectangle"]) }
    public var slash: SymbolVariants { SymbolVariants(names: names + ["slash"]) }
    public func contains(_ other: SymbolVariants) -> Bool { other.names.allSatisfy(names.contains) }
}
public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
    public static let all: SafeAreaRegions = [.container, .keyboard]
}

public protocol TextSelectability { static var allowsSelection: Bool { get } }
public struct EnabledTextSelectability: TextSelectability { public static var allowsSelection: Bool { true } }
public struct DisabledTextSelectability: TextSelectability { public static var allowsSelection: Bool { false } }
extension TextSelectability where Self == EnabledTextSelectability { public static var enabled: EnabledTextSelectability { .init() } }
extension TextSelectability where Self == DisabledTextSelectability { public static var disabled: DisabledTextSelectability { .init() } }

struct TextSelectableKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// `.textSelection(.enabled)`: text can be selected and copied.
    public var isTextSelectable: Bool {
        get { self[TextSelectableKey.self] }
        set { self[TextSelectableKey.self] = newValue }
    }
}

// MARK: - Appearance environment

/// Sidebar icon size (System Settings › Appearance).
public enum SidebarRowSize: Hashable, Sendable, CaseIterable { case small, medium, large }
public enum BackgroundProminence: Hashable, Sendable { case standard, increased }

struct ForegroundStyleLevelsKey: EnvironmentKey { static let defaultValue: [AnyShapeStyle] = [] }
struct SidebarRowSizeKey: EnvironmentKey { static let defaultValue = SidebarRowSize.medium }
struct BackgroundProminenceKey: EnvironmentKey { static let defaultValue = BackgroundProminence.standard }
struct AppearsActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var foregroundStyleLevels: [AnyShapeStyle] {
        get { self[ForegroundStyleLevelsKey.self] }
        set { self[ForegroundStyleLevelsKey.self] = newValue }
    }
    public var sidebarRowSize: SidebarRowSize {
        get { self[SidebarRowSizeKey.self] }
        set { self[SidebarRowSizeKey.self] = newValue }
    }
    public var backgroundProminence: BackgroundProminence {
        get { self[BackgroundProminenceKey.self] }
        set { self[BackgroundProminenceKey.self] = newValue }
    }
    /// Whether the window is key (backends update it).
    public var appearsActive: Bool {
        get { self[AppearsActiveKey.self] }
        set { self[AppearsActiveKey.self] = newValue }
    }
}

extension View {
    /// Deprecated form of `.environment(\.colorScheme, ...)`.
    public func colorScheme(_ colorScheme: ColorScheme) -> some View {
        environment(\.colorScheme, colorScheme)
    }
}
