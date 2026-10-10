import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - LocalizedStringKey

/// A localization key. Interpolations become format specifiers in the key, as in SwiftUI
/// (`"Hello \(name)"` → key `"Hello %@"`), with the values kept as arguments.
public struct LocalizedStringKey: Equatable, @unchecked Sendable, ExpressibleByStringInterpolation {
    var key: String
    var arguments: [FormatArgument]
    /// Created by interpolation: the key is a format string (literal `%` escaped as `%%`).
    var hasFormatting: Bool

    public init(_ value: String) {
        key = value
        arguments = []
        hasFormatting = false
    }

    public init(stringLiteral value: String) { self.init(value) }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
        hasFormatting = true
    }

    public enum FormatArgument: Equatable {
        case string(String)
        case int(Int64)
        case uint(UInt64)
        case double(Double)
        case text(Text)
        case image(Image)

        var cVarArg: CVarArg {
            switch self {
            case .string(let value): return value
            case .int(let value): return value
            case .uint(let value): return value
            case .double(let value): return value
            case .text, .image: return ""
            }
        }
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [FormatArgument] = []

        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity + interpolationCount * 2) }

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation(_ string: String) {
            key += "%@"
            arguments.append(.string(string))
        }

        public mutating func appendInterpolation<T: _FormatSpecifiable>(_ value: T) {
            key += value._specifier
            arguments.append(value._formatArgument)
        }

        public mutating func appendInterpolation<T: _FormatSpecifiable>(_ value: T, specifier: String) {
            key += specifier
            arguments.append(value._formatArgument)
        }

        public mutating func appendInterpolation<Subject: ReferenceConvertible>(_ subject: Subject, formatter: Formatter? = nil) {
            key += "%@"
            // Boxed explicitly: bridging the generic subject directly crashes the compiler.
            let object: Any = subject as Any
            arguments.append(.string(formatter.flatMap { $0.string(for: object) } ?? String(describing: subject)))
        }

        public mutating func appendInterpolation<Subject: NSObject>(_ subject: Subject, formatter: Formatter? = nil) {
            key += "%@"
            arguments.append(.string(formatter?.string(for: subject) ?? subject.description))
        }

        public mutating func appendInterpolation<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String {
            key += "%@"
            arguments.append(.string(format.format(input)))
        }

        public mutating func appendInterpolation(_ text: Text) {
            key += "%@"
            arguments.append(.text(text))
        }

        public mutating func appendInterpolation(_ image: Image) {
            key += "%@"
            arguments.append(.image(image))
        }

        public mutating func appendInterpolation(_ attributedString: AttributedString) {
            key += "%@"
            arguments.append(.text(Text(attributedString)))
        }

        public mutating func appendInterpolation(_ date: Date, style: Text.DateStyle) {
            key += "%@"
            arguments.append(.text(Text(date, style: style)))
        }

        public mutating func appendInterpolation(_ dates: ClosedRange<Date>) {
            key += "%@"
            arguments.append(.text(Text(dates)))
        }

        /// Any other value, described (SwiftUI requires a supported type; this is a superset).
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append(.string(String(describing: value)))
        }
    }

    /// The key formatted with its arguments, without translation (Text and Image arguments are
    /// rendered as their plain strings).
    var formattedString: String {
        LocalizedTextResolver.pieces(format: key, arguments: arguments, hasFormatting: hasFormatting).map {
            if case .string(let string) = $0 { return string } else { return "" }
        }.joined()
    }
}

extension LocalizedStringKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(arguments.count)
    }
}

/// Values that interpolate into a `LocalizedStringKey` with a printf specifier.
public protocol _FormatSpecifiable: Equatable {
    var _specifier: String { get }
    var _formatArgument: LocalizedStringKey.FormatArgument { get }
}

extension Int: _FormatSpecifiable {
    public var _specifier: String { "%lld" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .int(Int64(self)) }
}
extension Int8: _FormatSpecifiable {
    public var _specifier: String { "%d" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .int(Int64(self)) }
}
extension Int16: _FormatSpecifiable {
    public var _specifier: String { "%d" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .int(Int64(self)) }
}
extension Int32: _FormatSpecifiable {
    public var _specifier: String { "%d" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .int(Int64(self)) }
}
extension Int64: _FormatSpecifiable {
    public var _specifier: String { "%lld" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .int(self) }
}
extension UInt: _FormatSpecifiable {
    public var _specifier: String { "%llu" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .uint(UInt64(self)) }
}
extension UInt8: _FormatSpecifiable {
    public var _specifier: String { "%u" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .uint(UInt64(self)) }
}
extension UInt16: _FormatSpecifiable {
    public var _specifier: String { "%u" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .uint(UInt64(self)) }
}
extension UInt32: _FormatSpecifiable {
    public var _specifier: String { "%u" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .uint(UInt64(self)) }
}
extension UInt64: _FormatSpecifiable {
    public var _specifier: String { "%llu" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .uint(self) }
}
extension Float: _FormatSpecifiable {
    public var _specifier: String { "%f" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .double(Double(self)) }
}
extension Double: _FormatSpecifiable {
    public var _specifier: String { "%lf" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .double(self) }
}
extension CGFloat: _FormatSpecifiable {
    public var _specifier: String { "%lf" }
    public var _formatArgument: LocalizedStringKey.FormatArgument { .double(Double(self)) }
}

// MARK: - Resolution

enum LocalizedTextResolver {
    enum Piece: Equatable {
        case string(String)
        case text(Text)
        case image(Image)
    }

    /// Private-use marker standing for a Text/Image argument while formatting.
    private static let marker: Character = "\u{F8FF}"

    /// Translates the key (bundle lookup; the key itself when there is no translation) and
    /// formats the arguments into it.
    static func pieces(for key: LocalizedStringKey, tableName: String?, bundle: Bundle?) -> [Piece] {
        let translated = (bundle ?? .main).localizedString(forKey: key.key, value: key.key, table: tableName)
        return pieces(format: translated, arguments: key.arguments, hasFormatting: key.hasFormatting)
    }

    static func pieces(format: String, arguments: [LocalizedStringKey.FormatArgument], hasFormatting: Bool) -> [Piece] {
        guard hasFormatting else { return [.string(format)] }
        // Text/Image arguments are formatted as markers, then split back out.
        var embedded: [Piece] = []
        let cArguments: [CVarArg] = arguments.map { argument in
            switch argument {
            case .text(let text):
                embedded.append(.text(text))
                return "\(marker)\(embedded.count - 1)\(marker)"
            case .image(let image):
                embedded.append(.image(image))
                return "\(marker)\(embedded.count - 1)\(marker)"
            default:
                return argument.cVarArg
            }
        }
        // Foundation applies stringsdict plural rules to translated formats.
        let formatted = String(format: format, locale: Locale.current, arguments: cArguments)
        guard !embedded.isEmpty else { return [.string(formatted)] }
        var result: [Piece] = []
        let parts = formatted.split(separator: marker, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index % 2 == 1, let slot = Int(part), embedded.indices.contains(slot) {
                result.append(embedded[slot])
            } else if !part.isEmpty {
                result.append(.string(String(part)))
            }
        }
        return result
    }
}

extension Text {
    /// The text with localized keys translated, formatted and parsed as inline Markdown.
    var expanded: Text {
        switch storage {
        case .localized(let key, let tableName, let bundle):
            let parts = LocalizedTextResolver.pieces(for: key, tableName: tableName, bundle: bundle).flatMap { piece -> [Text] in
                switch piece {
                case .string(let string): return Text.markdown(string)
                case .text(let text): return [text]
                case .image(let image): return [Text(image)]
                }
            }
            var result = parts.count == 1 ? parts[0] : Text(storage: .concatenated(parts))
            result.modifiers = result.modifiers + modifiers
            return result
        default:
            return self
        }
    }

    /// Inline Markdown (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[link](url)`), as
    /// SwiftUI applies to localized string keys.
    static func markdown(_ string: String) -> [Text] {
        guard string.contains(where: { "*_`~[\\".contains($0) }) else { return [Text(verbatim: string)] }
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: string, options: options) else { return [Text(verbatim: string)] }
        var parts: [Text] = []
        for run in attributed.runs {
            var part = Text(verbatim: String(attributed[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { part = part.bold() }
                if intent.contains(.emphasized) { part = part.italic() }
                if intent.contains(.code) { part = part.fontDesign(.monospaced) }
                if intent.contains(.strikethrough) { part = part.strikethrough() }
            }
            if let link = run.link { part.modifiers.append(.link(link)) }
            parts.append(part)
        }
        return parts.isEmpty ? [Text(verbatim: "")] : parts
        #else
        return [Text(verbatim: string)]
        #endif
    }
}
