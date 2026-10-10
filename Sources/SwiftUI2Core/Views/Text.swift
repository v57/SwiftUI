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
    public struct Width: Hashable, Sendable {
        public let value: CGFloat
        public init(_ value: CGFloat) { self.value = value }
        public static let compressed = Width(-0.3), condensed = Width(-0.2), standard = Width(0), expanded = Width(0.2)
    }
    public func width(_ width: Width) -> Font {
        var copy = self
        copy.widthValue = width.value
        return copy
    }

    public enum Leading: Hashable, Sendable { case standard, tight, loose }

    public func leading(_ leading: Leading) -> Font {
        var copy = self
        copy.leadingValue = leading
        return copy
    }

    public func smallCaps() -> Font {
        var copy = self
        copy.caps = .smallCaps
        return copy
    }

    public func lowercaseSmallCaps() -> Font {
        var copy = self
        copy.caps = .lowercaseSmallCaps
        return copy
    }

    public func uppercaseSmallCaps() -> Font {
        var copy = self
        copy.caps = .uppercaseSmallCaps
        return copy
    }

    public enum _Caps: Hashable, Sendable { case none, smallCaps, lowercaseSmallCaps, uppercaseSmallCaps }

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
        /// A named font (`Font.custom`, platform fonts); nil for the system font.
        public var name: String? = nil
        /// Width axis (`Font.Width.value`: condensed < 0 < expanded).
        public var width: CGFloat = 0
        public var leading: Leading = .standard
        public var caps: _Caps = .none

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
        /// A named font, optionally scaled relative to a text style.
        case custom(name: String, size: CGFloat, relativeTo: TextStyle?)
    }

    /// Font used when the environment has none.
    static let defaultFont = Font(base: .defaultBody)

    var base: Base
    var weight: Weight?
    var design: Design = .default
    var isItalic = false
    var monospacedDigits = false
    var widthValue: CGFloat = 0
    var leadingValue: Leading = .standard
    var caps: _Caps = .none

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

    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font {
        Font(base: .system(size: size), weight: weight, design: design ?? .default)
    }

    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font {
        Font(base: .style(style), weight: weight, design: design ?? .default)
    }

    /// A font by name (PostScript or family name); falls back to the system font if missing.
    public static func custom(_ name: String, size: CGFloat) -> Font {
        Font(base: .custom(name: name, size: size, relativeTo: .body))
    }

    public static func custom(_ name: String, size: CGFloat, relativeTo textStyle: TextStyle) -> Font {
        Font(base: .custom(name: name, size: size, relativeTo: textStyle))
    }

    public static func custom(_ name: String, fixedSize: CGFloat) -> Font {
        Font(base: .custom(name: name, size: fixedSize, relativeTo: nil))
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

    /// Resolves the font; text styles (and custom fonts relative to one) scale with `dynamicType`.
    public func resolve(_ dynamicType: DynamicTypeSize = .large) -> Resolved {
        var size: CGFloat
        var resolvedWeight: Weight
        var style: TextStyle?
        var scales = true
        switch base {
        case .style(let textStyle):
            (size, resolvedWeight) = Font.metrics(textStyle)
            style = textStyle
        case .system(let pointSize): (size, resolvedWeight) = (pointSize, .regular); scales = false
        case .defaultBody: (size, resolvedWeight) = Font.metrics(.body)
        case .custom(_, let pointSize, let relativeTo): (size, resolvedWeight) = (pointSize, .regular); scales = relativeTo != nil
        }
        if scales, dynamicType != .large { size = (size * dynamicType._scale).rounded() }
        if let weight { resolvedWeight = weight }
        var resolved = Resolved(size: size, weight: resolvedWeight, design: design, italic: isItalic, monospacedDigit: monospacedDigits, textStyle: style)
        if case .custom(let name, _, _) = base { resolved.name = name }
        resolved.width = widthValue
        resolved.leading = leadingValue
        resolved.caps = caps
        return resolved
    }
}

// MARK: - LocalizedStringKey

// MARK: - Text

public struct ResolvedText: Hashable, Sendable {
    public var string: String
    public var font: Font.Resolved
    public var color: Color.Resolved
    public var lineLimit: Int?
    public var alignment: TextAlignment
    public var strikethrough: Bool
    public var underline: Bool
    /// Extra space between characters (`tracking` / `kerning`).
    public var tracking: CGFloat = 0
    public var baselineOffset: CGFloat = 0
    public var background: Color.Resolved? = nil
    /// Styled runs for concatenated text (`Text + Text`); empty for uniformly styled text.
    public var runs: [Run] = []
    /// Markdown link of uniformly styled text.
    public var link: URL? = nil
    /// Extra space between lines.
    public var lineSpacing: CGFloat = 0
    public var truncationMode: TruncationMode = .tail
    /// The font may shrink down to this factor to fit (`minimumScaleFactor`).
    public var minimumScaleFactor: CGFloat = 1
    public var allowsTightening = false
    /// Drawn as placeholder shapes (`redacted(reason:)`).
    public var isRedacted = false
    /// Text filled with a gradient (`foregroundStyle` gradients).
    public var gradient: ResolvedGradient? = nil
    public var strikethroughStyle: LineStyle? = nil
    public var underlineStyle: LineStyle? = nil
    /// Lines reserved even when the text is shorter (`lineLimit(_:reservesSpace:)`, ranges).
    public var minimumLines: Int? = nil

    public struct LineStyle: Hashable, Sendable {
        public var pattern: Text.LineStyle.Pattern
        public var color: Color.Resolved?
    }
    public var contentTransition = ContentTransition.interpolate

    /// The text with all fonts scaled (used for `minimumScaleFactor`).
    public func scaled(by factor: CGFloat) -> ResolvedText {
        guard factor != 1 else { return self }
        var copy = self
        copy.font.size *= factor
        copy.runs = runs.map { run in
            var run = run
            run.font.size *= factor
            run.image?.pointSize *= factor
            return run
        }
        return copy
    }

    public struct Run: Hashable, Sendable {
        public var string: String
        public var font: Font.Resolved
        public var color: Color.Resolved
        public var strikethrough: Bool
        public var underline: Bool
        public var tracking: CGFloat = 0
        public var baselineOffset: CGFloat = 0
        public var background: Color.Resolved? = nil
        /// An inline image drawn in place of the run's text (U+FFFC).
        public var image: ResolvedImage? = nil
        public var link: URL? = nil
        public var gradient: ResolvedGradient? = nil
        public var strikethroughStyle: LineStyle? = nil
        public var underlineStyle: LineStyle? = nil
    }

    /// The runs to draw (a single run for uniform text).
    public var effectiveRuns: [Run] {
        runs.isEmpty ? [Run(string: string, font: font, color: color, strikethrough: strikethrough, underline: underline, tracking: tracking, baselineOffset: baselineOffset, background: background, link: link, gradient: gradient, strikethroughStyle: strikethroughStyle, underlineStyle: underlineStyle)] : runs
    }

    /// The part of the text that affects measurement.
    var layoutKey: TextLayoutKey {
        TextLayoutKey(string: string, font: font, lineLimit: lineLimit, tracking: tracking, runFonts: runs.map(\.font), runTracking: runs.map(\.tracking),
                      lineSpacing: lineSpacing, minimumScaleFactor: minimumScaleFactor)
    }
}

struct TextLayoutKey: Hashable {
    var string: String
    var font: Font.Resolved
    var lineLimit: Int?
    var tracking: CGFloat = 0
    var runFonts: [Font.Resolved] = []
    var runTracking: [CGFloat] = []
    var lineSpacing: CGFloat = 0
    var minimumScaleFactor: CGFloat = 1
}

public struct Text: Equatable {
    enum Storage: Equatable {
        case verbatim(String)
        case concatenated([Text])
        /// Translated, formatted and Markdown-parsed when resolved (`expanded`).
        case localized(LocalizedStringKey, tableName: String?, bundle: Bundle?)
        /// An inline image (`Text(Image)`, `"\(Image(...))"` interpolation).
        case image(Image)
        /// A date shown relative to now (`.relative`, `.offset`, `.timer`): formatted when resolved.
        case date(Date, DateStyle)
        case timerInterval(ClosedRange<Date>, pauseTime: Date?, countsDown: Bool, showsHours: Bool)
        /// A formatted value, formatted in the environment's locale when resolved.
        case formatted(_FormattedValue)
    }

    enum Modifier: Equatable {
        case font(Font?)
        case color(Color?)
        case style(AnyShapeStyle)
        case weight(Font.Weight?)
        case italic
        case strikethrough(Text.LineStyle?)
        case underline(Text.LineStyle?)
        case monospacedDigit
        case tracking(CGFloat)
        case baselineOffset(CGFloat)
        case background(Color?)
        case design(Font.Design)
        case link(URL)
        case width(CGFloat)
    }

    var storage: Storage
    var modifiers: [Modifier] = []

    public init(verbatim content: String) { storage = .verbatim(content) }
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) { storage = .verbatim(String(content)) }
    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
        storage = .localized(key, tableName: tableName, bundle: bundle)
    }

    public init(_ image: Image) { storage = .image(image) }
    public init<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String {
        storage = .formatted(_FormattedValue(input: input, format: format))
    }

    public enum DateStyle: Hashable, Sendable { case time, date, relative, offset, timer }

    public init(_ date: Date, style: DateStyle) {
        switch style {
        case .time, .date: storage = .verbatim(Text.format(date, style: style, now: Date()))
        case .relative, .offset, .timer: storage = .date(date, style)
        }
    }

    /// A timer counting within `timerInterval` (live; frozen at `pauseTime`).
    public init(timerInterval: ClosedRange<Date>, pauseTime: Date? = nil, countsDown: Bool = true, showsHours: Bool = true) {
        storage = .timerInterval(timerInterval, pauseTime: pauseTime, countsDown: countsDown, showsHours: showsHours)
    }

    /// Whether the text changes with time (updated every second while shown).
    var isTimeDependent: Bool {
        switch storage {
        case .date, .timerInterval: return true
        case .concatenated(let parts): return parts.contains(where: \.isTimeDependent)
        default: return false
        }
    }

    static func format(_ date: Date, style: DateStyle, now: Date) -> String {
        switch style {
        case .time:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        case .date:
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            return formatter.string(from: date)
        case .relative, .offset:
            #if !canImport(Darwin)
            // swift-corelibs-foundation has no DateComponentsFormatter.
            let interval = date.timeIntervalSince(now)
            let text = componentsString(abs(interval).rounded(.down), short: style == .relative, maximumUnits: style == .relative ? 2 : 1)
            return style == .offset ? (interval < 0 ? "-" : "+") + text : text
            #else
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = style == .relative ? .short : .full
            formatter.allowedUnits = [.year, .month, .day, .hour, .minute, .second]
            formatter.maximumUnitCount = style == .relative ? 2 : 1
            let interval = date.timeIntervalSince(now)
            let text = formatter.string(from: abs(interval).rounded(.down)) ?? ""
            return style == .offset ? (interval < 0 ? "-" : "+") + text : text
            #endif
        case .timer:
            return timerString(abs(date.timeIntervalSince(now)), showsHours: true)
        }
    }

    /// "2 hr, 5 min" / "2 hours" (DateComponentsFormatter's English short/full unit styles).
    static func componentsString(_ seconds: TimeInterval, short: Bool, maximumUnits: Int) -> String {
        var remaining = Int(seconds)
        let units: [(Int, String, String)] = [(31_536_000, "yr", "year"), (2_592_000, "mth", "month"), (86_400, "day", "day"),
                                              (3600, "hr", "hour"), (60, "min", "minute"), (1, "sec", "second")]
        var parts: [String] = []
        for (size, shortName, longName) in units where parts.count < maximumUnits {
            let count = remaining / size
            guard count > 0 || (size == 1 && parts.isEmpty) else { continue }
            remaining -= count * size
            let name = short ? (shortName == "day" && count != 1 ? "days" : shortName) : longName + (count == 1 ? "" : "s")
            parts.append("\(count) \(name)")
        }
        return parts.joined(separator: ", ")
    }

    static func timerString(_ seconds: TimeInterval, showsHours: Bool) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if showsHours, hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", showsHours ? minutes : total / 60, secs)
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

    public func fontDesign(_ design: Font.Design?) -> Text { adding(.design(design ?? .default)) }
    public func fontWidth(_ width: Font.Width?) -> Text { adding(.width(width?.value ?? 0)) }
    public func kerning(_ kerning: CGFloat) -> Text { adding(.tracking(kerning)) }
    public func tracking(_ tracking: CGFloat) -> Text { adding(.tracking(tracking)) }
    public func baselineOffset(_ offset: CGFloat) -> Text { adding(.baselineOffset(offset)) }

    /// Styled text from an attributed string (font, colors, underline, strikethrough, tracking).
    @_disfavoredOverload public init(_ attributedContent: AttributedString) {
        var parts: [Text] = []
        for run in attributedContent.runs {
            var part = Text(verbatim: String(attributedContent[run.range].characters))
            if let font = run[TextAttributes.FontAttribute.self] { part = part.font(font) }
            if let color = run[TextAttributes.ForegroundColorAttribute.self] { part = part.foregroundColor(color) }
            if let color = run[TextAttributes.BackgroundColorAttribute.self] { part.modifiers.append(.background(color)) }
            // Platform scopes (AppKit's tracking, underline, ...) are read by the backend.
            if let bridge = TextAttributes.platformBridge { part.modifiers += bridge(attributedContent[run.range]).map(\.modifier) }
            parts.append(part)
        }
        storage = parts.count == 1 ? parts[0].storage : .concatenated(parts)
        modifiers = parts.count == 1 ? parts[0].modifiers : []
    }

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
    public func strikethrough(_ isActive: Bool = true, pattern: LineStyle.Pattern = .solid, color: Color? = nil) -> Text {
        adding(.strikethrough(isActive ? LineStyle(pattern: pattern, color: color) : nil))
    }
    public func underline(_ isActive: Bool = true, pattern: LineStyle.Pattern = .solid, color: Color? = nil) -> Text {
        adding(.underline(isActive ? LineStyle(pattern: pattern, color: color) : nil))
    }
    public func monospacedDigit() -> Text { adding(.monospacedDigit) }

    public static func + (lhs: Text, rhs: Text) -> Text {
        Text(storage: .concatenated([lhs, rhs]))
    }

    init(storage: Storage) { self.storage = storage }

    public var plainString: String {
        switch storage {
        case .verbatim(let string): return string
        case .concatenated(let parts): return parts.map(\.plainString).joined()
        case .localized: return expanded.plainString
        case .image: return ""
        case let .date(date, style): return Text.format(date, style: style, now: Date())
        case .formatted(let value): return value.string(in: .autoupdatingCurrent)
        case let .timerInterval(range, pauseTime, countsDown, showsHours):
            let now = min(max(pauseTime ?? Date(), range.lowerBound), range.upperBound)
            let elapsed = countsDown ? range.upperBound.timeIntervalSince(now) : now.timeIntervalSince(range.lowerBound)
            return Text.timerString(elapsed, showsHours: showsHours)
        }
    }

    public func resolve(in environment: EnvironmentValues) -> ResolvedText {
        if case .localized = storage { return expanded.resolve(in: environment) }
        if case .formatted(let value) = storage {
            return Text(verbatim: value.string(in: environment.locale)).withModifiers(modifiers).resolve(in: environment)
        }
        if case .image(let image) = storage {
            var result = resolveStyle(in: environment, modifiers: modifiers)
            result.string = "\u{FFFC}"
            var run = result.effectiveRuns[0]
            var resolved = image.resolve(in: environment)
            resolved.pointSize = result.font.size
            resolved.weight = result.font.weight
            if resolved.tint != nil { resolved.tint = result.color }
            run.image = resolved
            result.runs = [run]
            return result
        }
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
        var strikethroughStyle = environment.textStrikethrough
        var underlineStyle = environment.textUnderline
        var gradient: ResolvedGradient?
        var tracking: CGFloat = environment._textTracking ?? 0
        var baselineOffset: CGFloat = environment._textBaselineOffset ?? 0
        var background: Color.Resolved?
        var link: URL?
        for modifier in modifiers {
            switch modifier {
            case .font(let value): font = value ?? .defaultFont
            case .color(let value): color = value?.resolve(in: environment)
            case .style(let style):
                color = style._resolveColor(in: environment)
                if case .gradient(let g) = style._resolvePaint(in: environment) { gradient = g } else { gradient = nil }
            case .weight(let weight): font = font.weight(weight ?? .regular)
            case .italic: font = font.italic()
            case .strikethrough(let value): strikethroughStyle = value
            case .underline(let value): underlineStyle = value
            case .monospacedDigit: font = font.monospacedDigit()
            case .tracking(let value): tracking = value
            case .baselineOffset(let value): baselineOffset = value
            case .background(let value): background = value?.resolve(in: environment)
            case .design(let design): font.design = design
            case .width(let value): font.widthValue = value
            case .link(let url):
                link = url
                color = Color.accentColor.resolve(in: environment)
            }
        }
        if color == nil, gradient == nil, let style = environment.foregroundStyle, case .gradient(let g) = style._resolvePaint(in: environment) {
            gradient = g
        }
        let strikethrough = strikethroughStyle != nil
        let underline = underlineStyle != nil
        var resolvedColor = color ?? ForegroundStyle()._resolveColor(in: environment)
        if !environment.isEnabled { resolvedColor.opacity *= 0.5 }
        var string = plainString
        switch environment.textCase {
        case .uppercase?: string = string.uppercased(with: environment.locale)
        case .lowercase?: string = string.lowercased(with: environment.locale)
        case nil: break
        }
        var resolved = ResolvedText(
            string: string,
            font: font.resolve(environment.dynamicTypeSize),
            color: resolvedColor,
            lineLimit: environment.lineLimit,
            alignment: environment.multilineTextAlignment,
            strikethrough: strikethrough,
            underline: underline,
            tracking: tracking,
            baselineOffset: baselineOffset,
            background: background,
            link: link
        )
        resolved.lineSpacing = environment.lineSpacing
        resolved.truncationMode = environment.truncationMode
        resolved.minimumScaleFactor = environment.minimumScaleFactor
        resolved.allowsTightening = environment.allowsTightening
        resolved.isRedacted = environment._isRedacted
        resolved.contentTransition = environment.contentTransition
        resolved.gradient = gradient
        resolved.strikethroughStyle = strikethroughStyle.map { ResolvedText.LineStyle(pattern: $0.pattern, color: $0.color?.resolve(in: environment)) }
        resolved.underlineStyle = underlineStyle.map { ResolvedText.LineStyle(pattern: $0.pattern, color: $0.color?.resolve(in: environment)) }
        resolved.minimumLines = environment.minimumLineLimit
        return resolved
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

// MARK: - AttributedString attributes

/// The attribute scope `Text(AttributedString)` understands (`container.font = ...`,
/// `container.foregroundColor = ...`).
public enum TextAttributes {
    public enum FontAttribute: AttributedStringKey { public typealias Value = Font; public static let name = "SwiftUI2.Font" }
    public enum ForegroundColorAttribute: AttributedStringKey { public typealias Value = Color; public static let name = "SwiftUI2.ForegroundColor" }
    public enum BackgroundColorAttribute: AttributedStringKey { public typealias Value = Color; public static let name = "SwiftUI2.BackgroundColor" }

    /// Text styling a backend reads from its platform attribute scope.
    public enum PlatformStyle: Sendable {
        case underline, strikethrough
        case tracking(CGFloat)
        case baselineOffset(CGFloat)

        var modifier: Text.Modifier {
            switch self {
            case .underline: .underline(Text.LineStyle())
            case .strikethrough: .strikethrough(Text.LineStyle())
            case .tracking(let value): .tracking(value)
            case .baselineOffset(let value): .baselineOffset(value)
            }
        }
    }

    /// Installed by backends (attributes whose value types the platform scopes already declare).
    nonisolated(unsafe) public static var platformBridge: ((AttributedSubstring) -> [PlatformStyle])?
}

extension AttributeScopes {
    public struct SwiftUI2Attributes: AttributeScope {
        public let font: TextAttributes.FontAttribute
        public let foregroundColor: TextAttributes.ForegroundColorAttribute
        public let backgroundColor: TextAttributes.BackgroundColorAttribute
        public let foundation: FoundationAttributes
    }

    public var swiftUI2: SwiftUI2Attributes.Type { SwiftUI2Attributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUI2Attributes, T>) -> T {
        self[T.self]
    }
}

/// A value with its format style (compared by the style and the formatted text).
public struct _FormattedValue: Equatable, @unchecked Sendable {
    let format: AnyHashable
    let text: String
    let formatter: (Locale) -> String

    init<F: FormatStyle>(input: F.FormatInput, format: F) where F.FormatOutput == String {
        self.format = AnyHashable(format)
        self.text = format.format(input)
        self.formatter = { locale in format.locale(locale).format(input) }
    }

    func string(in locale: Locale) -> String { formatter(locale) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.format == rhs.format && lhs.text == rhs.text }
}
