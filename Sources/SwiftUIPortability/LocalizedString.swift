// `String(localized:)` and `String.LocalizationValue`, which Apple's Foundation has and swift-corelibs-foundation
// doesn't. Built off Apple platforms only: on them the kits call Foundation's own, so Xcode still extracts their
// strings (SWIFT_EMIT_LOC_STRINGS reads the calls to Foundation's API). Keys match Foundation's: an interpolation
// becomes its printf specifier (`"Open \(name)"` → `"Open %@"`, an Int `%lld`), so the same compiled tables serve both.
#if !canImport(ObjectiveC)
import Foundation

/// How `String(localized:)` looks a key up and which locale formats it. SwiftUI's `_AppLocale` sets both at launch
/// (the app's language, its `.lproj` and language packs); until then a key is looked up in the bundle as it is.
public enum _StringLocalization {
    nonisolated(unsafe) public static var lookup: ((_ bundle: Bundle, _ key: String, _ table: String?) -> String)?
    nonisolated(unsafe) public static var locale: Locale?

    static func string(key: String, table: String?, bundle: Bundle?) -> String {
        let bundle = bundle ?? .main
        if let lookup { return lookup(bundle, key, table) }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
}

extension String {
    /// A string to translate, with its interpolations as format arguments.
    public struct LocalizationValue: Equatable, Hashable, Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
        enum Argument: Equatable, Hashable, Sendable {
            case string(String)
            case int(Int64)
            case uint(UInt64)
            case double(Double)
            case float(Float)

            var cVarArg: CVarArg {
                switch self {
                case .string(let value): return value
                case .int(let value): return value
                case .uint(let value): return value
                case .double(let value): return value
                case .float(let value): return value
                }
            }
        }

        /// The key: a format string when it was interpolated (a literal `%` escaped as `%%`), else the text itself.
        var key: String
        var arguments: [Argument]
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

        /// The key formatted with its arguments, untranslated.
        public var description: String { String.format(key, arguments: arguments, hasFormatting: hasFormatting, locale: nil) }

        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [Argument] = []

            public init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity + interpolationCount * 3)
            }

            public mutating func appendLiteral(_ literal: String) {
                key += literal.contains("%") ? literal.replacingOccurrences(of: "%", with: "%%") : literal
            }

            mutating func append(_ specifier: String, _ argument: Argument) {
                key += specifier
                arguments.append(argument)
            }

            public mutating func appendInterpolation(_ string: String) { append("%@", .string(string)) }
            public mutating func appendInterpolation(_ value: Int) { append("%lld", .int(Int64(value))) }
            public mutating func appendInterpolation(_ value: Int8) { append("%d", .int(Int64(value))) }
            public mutating func appendInterpolation(_ value: Int16) { append("%d", .int(Int64(value))) }
            public mutating func appendInterpolation(_ value: Int32) { append("%d", .int(Int64(value))) }
            public mutating func appendInterpolation(_ value: Int64) { append("%lld", .int(value)) }
            public mutating func appendInterpolation(_ value: UInt) { append("%llu", .uint(UInt64(value))) }
            public mutating func appendInterpolation(_ value: UInt8) { append("%u", .uint(UInt64(value))) }
            public mutating func appendInterpolation(_ value: UInt16) { append("%u", .uint(UInt64(value))) }
            public mutating func appendInterpolation(_ value: UInt32) { append("%u", .uint(UInt64(value))) }
            public mutating func appendInterpolation(_ value: UInt64) { append("%llu", .uint(value)) }
            public mutating func appendInterpolation(_ value: Float) { append("%f", .float(value)) }
            public mutating func appendInterpolation(_ value: Double) { append("%lf", .double(value)) }
            public mutating func appendInterpolation(_ value: CGFloat) { append("%lf", .double(Double(value))) }

            /// A value with its own printf specifier (`"\(ratio, specifier: "%.1f")"`).
            public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, specifier: String) {
                append(specifier, .double(Double(value)))
            }

            public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, specifier: String) {
                if T.isSigned { append(specifier, .int(Int64(value))) } else { append(specifier, .uint(UInt64(value))) }
            }

            public mutating func appendInterpolation<Subject: ReferenceConvertible>(_ subject: Subject, formatter: Formatter? = nil) {
                let object: Any = subject as Any
                append("%@", .string(formatter.flatMap { $0.string(for: object) } ?? String(describing: subject)))
            }

            public mutating func appendInterpolation<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String {
                append("%@", .string(format.format(input)))
            }

            public mutating func appendInterpolation(_ value: LocalizationValue) {
                append("%@", .string(String(localized: value)))
            }

            /// Any other value, described (Foundation accepts fewer types; this is a superset).
            public mutating func appendInterpolation<T>(_ value: T) { append("%@", .string(String(describing: value))) }
        }
    }

    /// `keyAndValue` translated into the app's language (the key itself when there's no translation) and formatted
    /// with its interpolations.
    public init(
        localized keyAndValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale? = nil,
        comment: StaticString? = nil
    ) {
        let translated = _StringLocalization.string(key: keyAndValue.key, table: table, bundle: bundle)
        self = String.format(
            translated, arguments: keyAndValue.arguments, hasFormatting: keyAndValue.hasFormatting,
            locale: locale ?? _StringLocalization.locale)
    }

    /// `key` translated into the app's language, else `defaultValue`, formatted with `defaultValue`'s interpolations.
    public init(
        localized key: StaticString, defaultValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil,
        locale: Locale? = nil, comment: StaticString? = nil
    ) {
        let key = "\(key)"
        let found = _StringLocalization.string(key: key, table: table, bundle: bundle)
        let translated = found == key ? defaultValue.key : found
        self = String.format(
            translated, arguments: defaultValue.arguments, hasFormatting: defaultValue.hasFormatting,
            locale: locale ?? _StringLocalization.locale)
    }

    fileprivate static func format(
        _ format: String, arguments: [LocalizationValue.Argument], hasFormatting: Bool, locale: Locale?
    ) -> String {
        guard hasFormatting else { return format }
        return String(format: format, locale: locale, arguments: arguments.map(\.cVarArg))
    }
}
#endif
