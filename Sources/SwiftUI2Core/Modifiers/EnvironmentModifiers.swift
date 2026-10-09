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

public struct _EnvironmentKeyWritingModifier<Value>: ViewModifier, EnvironmentModifier {
    public var keyPath: WritableKeyPath<EnvironmentValues, Value>
    public var value: Value

    public init(keyPath: WritableKeyPath<EnvironmentValues, Value>, value: Value) {
        self.keyPath = keyPath
        self.value = value
    }

    public typealias Body = Never

    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues> {
        let keyPath = AnyAttribute.withoutDependencies { modifier.value.keyPath }
        return makeWritingEnvironment(parent: environment, subgraph: subgraph, value: { modifier.value.value }) { environment, value in
            environment[keyPath: keyPath] = value
        }
    }
}

public struct _EnvironmentTransformModifier<Value>: ViewModifier, EnvironmentModifier {
    let keyPath: WritableKeyPath<EnvironmentValues, Value>
    let transform: (inout Value) -> Void
    public typealias Body = Never

    static func makeEnvironment(modifier: Attribute<Self>, environment: Attribute<EnvironmentValues>, subgraph: Subgraph) -> Attribute<EnvironmentValues> {
        let keyPath = AnyAttribute.withoutDependencies { modifier.value.keyPath }
        return makeWritingEnvironment(parent: environment, subgraph: subgraph, value: {
            var value = environment.value[keyPath: keyPath]
            modifier.value.transform(&value)
            return value
        }) { environment, value in
            environment[keyPath: keyPath] = value
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

    public func foregroundColor(_ color: Color?) -> some View {
        environment(\.foregroundStyle, color.map { AnyShapeStyle($0) })
    }

    public func tint(_ tint: Color?) -> some View {
        environment(\.tint, tint)
    }

    public func lineLimit(_ number: Int?) -> some View {
        environment(\.lineLimit, number)
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
    public func symbolVariant(_ variant: SymbolVariants) -> some View { self }
    public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { self }
    public func accessibilityLabel(_ label: Text) -> some View { self }
    public func accessibilityHint<S: StringProtocol>(_ hint: S) -> some View { self }
    public func accessibilityIdentifier(_ identifier: String) -> some View { self }
    public func accessibilityHidden(_ hidden: Bool) -> some View { self }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { self }
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { self }
    public func edgesIgnoringSafeArea(_ edges: Edge.Set) -> some View { self }
    public func statusBarHidden(_ hidden: Bool = true) -> some View { self }
    public func persistentSystemOverlays(_ visibility: Visibility) -> some View { self }
    public func badge(_ count: Int) -> some View { self }
    public func badge<S: StringProtocol>(_ label: S?) -> some View { self }
}

public enum SymbolRenderingMode: Sendable { case monochrome, multicolor, hierarchical, palette }
public struct SymbolVariants: Sendable {
    public static let none = SymbolVariants()
    public static let fill = SymbolVariants()
    public static let circle = SymbolVariants()
    public static let square = SymbolVariants()
    public static let slash = SymbolVariants()
}
public enum AccessibilityChildBehavior: Sendable { case ignore, contain, combine }
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
