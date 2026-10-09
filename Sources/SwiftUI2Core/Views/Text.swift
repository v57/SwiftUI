import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Font

public struct Font: Hashable, Sendable {
    public enum TextStyle: Hashable, Sendable, CaseIterable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
    }

    public enum Design: Hashable, Sendable { case `default`, serif, rounded, monospaced }

    public struct Weight: Hashable, Sendable {
        public let value: Double
        public static let ultraLight = Weight(value: -0.8)
        public static let thin = Weight(value: -0.6)
        public static let light = Weight(value: -0.4)
        public static let regular = Weight(value: 0)
        public static let medium = Weight(value: 0.23)
        public static let semibold = Weight(value: 0.3)
        public static let bold = Weight(value: 0.4)
        public static let heavy = Weight(value: 0.56)
        public static let black = Weight(value: 0.62)
    }

    /// Platform-independent resolved font; backends map it to NSFont / PangoFontDescription / ...
    public struct Resolved: Hashable, Sendable {
        public var size: CGFloat
        public var weight: Weight
        public var design: Design
        public var italic: Bool
        public var monospacedDigit: Bool
        /// The text style of an explicit style font (`.body`, `.title`, ...); nil for sized fonts and
        /// the environment's default font. Backends use it for style metrics (leading).
        public var textStyle: TextStyle? = nil

        public init(size: CGFloat, weight: Weight = .regular, design: Design = .default, italic: Bool = false, monospacedDigit: Bool = false, textStyle: TextStyle? = nil) {
            self.size = size
            self.weight = weight
            self.design = design
            self.italic = italic
            self.monospacedDigit = monospacedDigit
            self.textStyle = textStyle
        }
    }

    enum Base: Hashable, Sendable {
        case style(TextStyle)
        case system(size: CGFloat)
        /// The environment's default font: body metrics, but without the body style's leading
        /// (stacked default-font texts have no gap in SwiftUI, explicit `.body` ones do).
        case defaultBody
    }

    /// Font used when the environment has none.
    static let defaultFont = Font(base: .defaultBody)

    var base: Base
    var weight: Weight?
    var design: Design = .default
    var isItalic = false
    var monospacedDigits = false

    init(base: Base, weight: Weight? = nil, design: Design = .default) {
        self.base = base
        self.weight = weight
        self.design = design
    }

    public static let largeTitle = Font(base: .style(.largeTitle))
    public static let title = Font(base: .style(.title))
    public static let title2 = Font(base: .style(.title2))
    public static let title3 = Font(base: .style(.title3))
    public static let headline = Font(base: .style(.headline))
    public static let subheadline = Font(base: .style(.subheadline))
    public static let body = Font(base: .style(.body))
    public static let callout = Font(base: .style(.callout))
    public static let footnote = Font(base: .style(.footnote))
    public static let caption = Font(base: .style(.caption))
    public static let caption2 = Font(base: .style(.caption2))

    public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font {
        Font(base: .system(size: size), weight: weight, design: design)
    }

    public static func system(_ style: TextStyle, design: Design = .default, weight: Weight? = nil) -> Font {
        Font(base: .style(style), weight: weight, design: design)
    }

    public func weight(_ weight: Weight) -> Font {
        var copy = self
        copy.weight = weight
        return copy
    }

    public func bold() -> Font { weight(.bold) }

    public func italic() -> Font {
        var copy = self
        copy.isItalic = true
        return copy
    }

    public func monospacedDigit() -> Font {
        var copy = self
        copy.monospacedDigits = true
        return copy
    }

    public func monospaced() -> Font {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    /// macOS text style metrics (point size, default weight).
    static func metrics(_ style: TextStyle) -> (CGFloat, Weight) {
        switch style {
        case .largeTitle: return (26, .regular)
        case .title: return (22, .regular)
        case .title2: return (17, .regular)
        case .title3: return (15, .regular)
        case .headline: return (13, .bold)
        case .subheadline: return (11, .regular)
        case .body: return (13, .regular)
        case .callout: return (12, .regular)
        case .footnote: return (10, .regular)
        case .caption: return (10, .regular)
        case .caption2: return (10, .medium)
        }
    }

    public func resolve() -> Resolved {
        let size: CGFloat
        var resolvedWeight: Weight
        var style: TextStyle?
        switch base {
        case .style(let textStyle):
            (size, resolvedWeight) = Font.metrics(textStyle)
            style = textStyle
        case .system(let pointSize): (size, resolvedWeight) = (pointSize, .regular)
        case .defaultBody: (size, resolvedWeight) = Font.metrics(.body)
        }
        if let weight { resolvedWeight = weight }
        return Resolved(size: size, weight: resolvedWeight, design: design, italic: isItalic, monospacedDigit: monospacedDigits, textStyle: style)
    }
}

// MARK: - LocalizedStringKey

public struct LocalizedStringKey: Hashable, Sendable, ExpressibleByStringInterpolation {
    let key: String

    public init(_ value: String) { key = value }
    public init(stringLiteral value: String) { key = value }

    public struct StringInterpolation: StringInterpolationProtocol {
        var output = ""
        public init(literalCapacity: Int, interpolationCount: Int) { output.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { output += literal }
        public mutating func appendInterpolation<T>(_ value: T) { output += String(describing: value) }
        public mutating func appendInterpolation(_ value: String) { output += value }
        public mutating func appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F) where F.FormatOutput == String {
            output += format.format(value)
        }
    }

    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.output }
}

// MARK: - Text

public struct ResolvedText: Hashable, Sendable {
    public var string: String
    public var font: Font.Resolved
    public var color: Color.Resolved
    public var lineLimit: Int?
    public var alignment: TextAlignment
    public var strikethrough: Bool
    public var underline: Bool
    /// Styled runs for concatenated text (`Text + Text`); empty for uniformly styled text.
    public var runs: [Run] = []

    public struct Run: Hashable, Sendable {
        public var string: String
        public var font: Font.Resolved
        public var color: Color.Resolved
        public var strikethrough: Bool
        public var underline: Bool
    }

    /// The runs to draw (a single run for uniform text).
    public var effectiveRuns: [Run] {
        runs.isEmpty ? [Run(string: string, font: font, color: color, strikethrough: strikethrough, underline: underline)] : runs
    }

    /// The part of the text that affects measurement.
    var layoutKey: TextLayoutKey { TextLayoutKey(string: string, font: font, lineLimit: lineLimit, runFonts: runs.map(\.font)) }
}

struct TextLayoutKey: Hashable {
    var string: String
    var font: Font.Resolved
    var lineLimit: Int?
    var runFonts: [Font.Resolved] = []
}

public struct Text: Equatable {
    enum Storage: Equatable {
        case verbatim(String)
        case concatenated([Text])
    }

    enum Modifier: Equatable {
        case font(Font?)
        case color(Color?)
        case style(AnyShapeStyle)
        case weight(Font.Weight?)
        case italic
        case strikethrough(Bool)
        case underline(Bool)
        case monospacedDigit
    }

    var storage: Storage
    var modifiers: [Modifier] = []

    public init(verbatim content: String) { storage = .verbatim(content) }
    public init<S: StringProtocol>(_ content: S) { storage = .verbatim(String(content)) }
    public init(_ key: LocalizedStringKey) { storage = .verbatim(key.key) }
    public init<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String {
        storage = .verbatim(format.format(input))
    }

    public enum DateStyle: Sendable { case time, date, relative, offset, timer }

    public init(_ date: Date, style: DateStyle) {
        let formatter = DateFormatter()
        switch style {
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            storage = .verbatim(formatter.string(from: date))
        case .date:
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            storage = .verbatim(formatter.string(from: date))
        case .relative, .offset:
            let relative = RelativeDateTimeFormatter()
            storage = .verbatim(relative.localizedString(for: date, relativeTo: Date()))
        case .timer:
            let seconds = Int(abs(date.timeIntervalSinceNow))
            storage = .verbatim(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }

    public init(_ range: ClosedRange<Date>) {
        let formatter = DateIntervalFormatter()
        storage = .verbatim(formatter.string(from: range.lowerBound, to: range.upperBound))
    }

    public func textCase(_ textCase: Text.Case?) -> Text {
        switch textCase {
        case .uppercase?: return Text(verbatim: plainString.uppercased()).withModifiers(modifiers)
        case .lowercase?: return Text(verbatim: plainString.lowercased()).withModifiers(modifiers)
        case nil: return self
        }
    }

    public enum Case: Sendable { case uppercase, lowercase }

    public func kerning(_ kerning: CGFloat) -> Text { self }
    public func tracking(_ tracking: CGFloat) -> Text { self }
    public func baselineOffset(_ offset: CGFloat) -> Text { self }

    func withModifiers(_ modifiers: [Modifier]) -> Text {
        var copy = self
        copy.modifiers = modifiers
        return copy
    }

    private func adding(_ modifier: Modifier) -> Text {
        var copy = self
        copy.modifiers.append(modifier)
        return copy
    }

    public func font(_ font: Font?) -> Text { adding(.font(font)) }
    public func foregroundColor(_ color: Color?) -> Text { adding(.color(color)) }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text {
        adding(.style(AnyShapeStyle(style)))
    }
    public func fontWeight(_ weight: Font.Weight?) -> Text { adding(.weight(weight)) }
    public func bold(_ isActive: Bool = true) -> Text { isActive ? adding(.weight(.bold)) : self }
    public func bold() -> Text { adding(.weight(.bold)) }
    public func italic(_ isActive: Bool = true) -> Text { isActive ? adding(.italic) : self }
    public func italic() -> Text { adding(.italic) }
    public func strikethrough(_ isActive: Bool = true) -> Text { adding(.strikethrough(isActive)) }
    public func underline(_ isActive: Bool = true) -> Text { adding(.underline(isActive)) }
    public func monospacedDigit() -> Text { adding(.monospacedDigit) }

    public static func + (lhs: Text, rhs: Text) -> Text {
        Text(storage: .concatenated([lhs, rhs]))
    }

    init(storage: Storage) { self.storage = storage }

    var plainString: String {
        switch storage {
        case .verbatim(let string): return string
        case .concatenated(let parts): return parts.map(\.plainString).joined()
        }
    }

    public func resolve(in environment: EnvironmentValues) -> ResolvedText {
        if case .concatenated(let parts) = storage {
            // Each part keeps its own style; this text's modifiers apply on top.
            let base = resolveStyle(in: environment, modifiers: modifiers)
            var runs: [ResolvedText.Run] = []
            for part in parts {
                var partText = part
                partText.modifiers = modifiers + part.modifiers
                runs.append(contentsOf: partText.resolve(in: environment).effectiveRuns)
            }
            var result = base
            result.string = runs.map(\.string).joined()
            result.runs = runs
            return result
        }
        return resolveStyle(in: environment, modifiers: modifiers)
    }

    private func resolveStyle(in environment: EnvironmentValues, modifiers: [Modifier]) -> ResolvedText {
        var font = environment.font ?? .defaultFont
        var color: Color.Resolved? = nil
        var strikethrough = environment.textStrikethrough
        var underline = environment.textUnderline
        for modifier in modifiers {
            switch modifier {
            case .font(let value): font = value ?? .defaultFont
            case .color(let value): color = value?.resolve(in: environment)
            case .style(let style): color = style._resolveColor(in: environment)
            case .weight(let weight): font = font.weight(weight ?? .regular)
            case .italic: font = font.italic()
            case .strikethrough(let value): strikethrough = value
            case .underline(let value): underline = value
            case .monospacedDigit: font = font.monospacedDigit()
            }
        }
        var resolvedColor = color ?? ForegroundStyle()._resolveColor(in: environment)
        if !environment.isEnabled { resolvedColor.opacity *= 0.5 }
        return ResolvedText(
            string: plainString,
            font: font.resolve(),
            color: resolvedColor,
            lineLimit: environment.lineLimit,
            alignment: environment.multilineTextAlignment,
            strikethrough: strikethrough,
            underline: underline
        )
    }
}

extension Text {
    /// Mirrors `Text.LineStyle` (patterns are drawn solid).
    public struct LineStyle: Hashable, Sendable {
        public enum Pattern: Hashable, Sendable { case solid, dot, dash, dashDot, dashDotDot }
        public var pattern: Pattern
        public var color: Color?
        public init(pattern: Pattern = .solid, color: Color? = nil) {
            self.pattern = pattern
            self.color = color
        }
        public static let single = LineStyle()
    }
}
