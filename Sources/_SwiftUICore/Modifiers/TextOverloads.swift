import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Text {
    public typealias Scale = TextScale

    /// How multiline text picks its alignment (layout direction vs. writing direction).
    public struct AlignmentStrategy: Hashable, Sendable {
        let value: Int
        public static let layoutBased = AlignmentStrategy(value: 0)
        public static let writingDirectionBased = AlignmentStrategy(value: 1)
        public static let `default` = layoutBased
    }

    /// How the writing direction of text is determined.
    public struct WritingDirectionStrategy: Hashable, Sendable {
        let value: Int
        public static let layoutBased = WritingDirectionStrategy(value: 0)
        public static let contentBased = WritingDirectionStrategy(value: 1)
        public static let `default` = layoutBased
    }

    public func textScale(_ scale: Text.Scale, isEnabled: Bool = true) -> Text { self }
    public func typesettingLanguage(_ language: Locale.Language, isEnabled: Bool = true) -> Text { self }
    public func typesettingLanguage(_ language: TypesettingLanguage, isEnabled: Bool = true) -> Text { self }
}

/// The language used for line breaking and hyphenation (layout uses the system's rules).
public struct TypesettingLanguage: Sendable {
    let language: Locale.Language?
    public static let automatic = TypesettingLanguage(language: nil)
    public static func explicit(_ language: Locale.Language) -> TypesettingLanguage { TypesettingLanguage(language: language) }
}

extension View {
    /// The width of the environment font (condensed / expanded faces).
    public func fontWidth(_ width: Font.Width?) -> some View {
        transformEnvironment(\.font) { font in font = (font ?? .body).width(width ?? .standard) }
    }

    public func typesettingLanguage(_ language: TypesettingLanguage, isEnabled: Bool = true) -> some View { self }

    /// Text alignment follows the layout direction (left-to-right here).
    public func multilineTextAlignment(strategy: Text.AlignmentStrategy) -> some View { self }

    public func writingDirection(strategy: Text.WritingDirectionStrategy) -> some View { self }

    /// Updates a preference from an anchor of this view.
    public func transformAnchorPreference<A, K: PreferenceKey>(key: K.Type = K.self, value: Anchor<A>.Source, transform: @escaping (inout K.Value, Anchor<A>) -> Void) -> some View {
        modifier(_AnchorPreferenceTransformModifier<A, K>(source: value, transform: transform))
    }
}

public struct _AnchorPreferenceTransformModifier<A, Key: PreferenceKey>: ViewModifier {
    let source: Anchor<A>.Source
    let transform: (inout Key.Value, Anchor<A>) -> Void
    public typealias Body = Never

    public static func _makeView(modifier: _GraphValue<Self>, inputs: _ViewInputs, body: @escaping @MainActor (_ViewInputs) -> _ViewOutputs) -> _ViewOutputs {
        var outputs = body(inputs)
        if inputs.requests(Key.self) {
            let geometry = inputs.geometry
            let source = modifier.attribute
            let inner = outputs.preferences.attribute(for: Key.self, in: inputs.subgraph)
            outputs.preferences[Key.self] = Attribute<Key.Value>(inputs.subgraph) {
                let current = source.value
                var value = inner?.value ?? Key.defaultValue
                current.transform(&value, Anchor(value: current.source.resolve(geometry.value)))
                return value
            }
        }
        return outputs
    }
}
