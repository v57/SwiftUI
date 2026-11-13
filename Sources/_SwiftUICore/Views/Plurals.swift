import Foundation

// Plural forms off Apple platforms. swift-corelibs-foundation stops the app on any `Bundle.localizedString` lookup of
// a key that a `.stringsdict` holds (Windows and Linux, Swift 6.4: an access violation while bridging the plural
// format), so SwiftUI reads `.stringsdict` files itself and picks the form for the count, as Apple's Foundation does.
// Foundation-only and built everywhere, so the rules are checked against ICU on macOS (`PluralTests`); only non-Apple
// platforms look strings up through it (`_AppLocale`).

/// CLDR's cardinal plural rules for whole numbers: "zero", "one", "two", "few", "many" or "other".
enum PluralRules {
    /// The category of `count` in `language` ("ru", "pt-BR", "pt_PT", "zh-Hans"); "other" for a language without rules.
    static func category(_ count: Int64, language: String) -> String {
        let n = count.magnitude
        let rule = rules[code(language)] ?? .other
        return rule.category(n)
    }

    /// The code the rules are listed under: the language, plus the region where it changes them (Portugal).
    static func code(_ language: String) -> String {
        let parts = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first.map(String.init) else { return "" }
        if first == "pt", parts.count > 1, parts[1] == "pt" { return "pt_pt" }
        return first
    }

    enum Rule {
        /// No plural forms.
        case other
        /// one: 1.
        case one
        /// one: 0 and 1.
        case zeroOne
        /// one: 0 and 1; many: whole millions (fr, pt).
        case zeroOneMillions
        /// one: 1; many: whole millions (es, it, ca, pt-PT).
        case oneMillions
        /// one: ends in 1 but not 11 (is, mk).
        case endsInOne
        /// one: 1, 2, 3 and anything not ending in 4, 6 or 9 (fil).
        case filipino
        /// one: 1; two: 2.
        case oneTwo
        /// one, few, many: ru, uk, be.
        case eastSlavic
        /// one, few, many: pl.
        case polish
        /// one: 1; few: 2–4 (cs, sk).
        case czech
        /// one, few: hr, sr, bs.
        case southSlavic
        /// one, two, few by the last two digits (sl).
        case slovenian
        /// one, few (lt).
        case lithuanian
        /// zero, one (lv).
        case latvian
        /// one, few (ro).
        case romanian
        /// zero, one, two, few, many (ar).
        case arabic
        /// one, two, few, many (ga).
        case irish
        /// zero, one, two, few, many (cy).
        case welsh
        /// one, two, few, many (mt).
        case maltese
        /// one: 1; two: 2 (he, whole numbers).
        case hebrew

        func category(_ n: UInt64) -> String {
            let n10 = n % 10, n100 = n % 100
            switch self {
            case .other: return "other"
            case .one: return n == 1 ? "one" : "other"
            case .zeroOne: return n <= 1 ? "one" : "other"
            case .zeroOneMillions:
                if n <= 1 { return "one" }
                return n % 1_000_000 == 0 ? "many" : "other"
            case .oneMillions:
                if n == 1 { return "one" }
                return n != 0 && n % 1_000_000 == 0 ? "many" : "other"
            case .endsInOne: return n10 == 1 && n100 != 11 ? "one" : "other"
            case .filipino: return n <= 3 || ![4, 6, 9].contains(n10) ? "one" : "other"
            case .oneTwo, .hebrew: return n == 1 ? "one" : n == 2 ? "two" : "other"
            case .eastSlavic:
                if n10 == 1 && n100 != 11 { return "one" }
                if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
                return "many"
            case .polish:
                if n == 1 { return "one" }
                if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
                return "many"
            case .czech: return n == 1 ? "one" : (2...4).contains(n) ? "few" : "other"
            case .southSlavic:
                if n10 == 1 && n100 != 11 { return "one" }
                if (2...4).contains(n10) && !(12...14).contains(n100) { return "few" }
                return "other"
            case .slovenian:
                switch n100 {
                case 1: return "one"
                case 2: return "two"
                case 3, 4: return "few"
                default: return "other"
                }
            case .lithuanian:
                if (11...19).contains(n100) { return "other" }
                if n10 == 1 { return "one" }
                return n10 >= 2 ? "few" : "other"
            case .latvian:
                if n10 == 0 || (11...19).contains(n100) { return "zero" }
                return n10 == 1 && n100 != 11 ? "one" : "other"
            case .romanian:
                if n == 1 { return "one" }
                return n == 0 || (1...19).contains(n100) ? "few" : "other"
            case .arabic:
                switch n {
                case 0: return "zero"
                case 1: return "one"
                case 2: return "two"
                default: return (3...10).contains(n100) ? "few" : (11...99).contains(n100) ? "many" : "other"
                }
            case .irish:
                switch n {
                case 1: return "one"
                case 2: return "two"
                case 3...6: return "few"
                case 7...10: return "many"
                default: return "other"
                }
            case .welsh:
                switch n {
                case 0: return "zero"
                case 1: return "one"
                case 2: return "two"
                case 3: return "few"
                case 6: return "many"
                default: return "other"
                }
            case .maltese:
                if n == 1 { return "one" }
                if n == 2 { return "two" }
                if n == 0 || (3...10).contains(n100) { return "few" }
                return (11...19).contains(n100) ? "many" : "other"
            }
        }
    }

    /// Every language v57 translates into (v57/Localizations), by CLDR's rules; a language not listed has none.
    static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        let groups: [(Rule, String)] = [
            (.one, "af an ast az bg brx ca ce chr ckb da de dv el en eo et eu fi fo fur fy gl gsw ha haw hu ia io ka kk"
                + " kl ks ku ky lb lij ml mn mr nb ne nl nn no or ps rm sc sd so sq sv sw ta te tk tr ug ur uz yi"),
            (.zeroOne, "ak am as bho bn doi fa ff gu hi hy kab kn kok ln mg nso pa pcm si ti wa zu"),
            (.zeroOneMillions, "fr pt"),
            (.oneMillions, "es it pt_pt ca vec"),
            (.endsInOne, "is mk"),
            (.filipino, "fil tl"),
            (.oneTwo, "iu naq sat se sma smi smj smn sms"),
            (.eastSlavic, "ru uk be"),
            (.polish, "pl"),
            (.czech, "cs sk"),
            (.southSlavic, "hr sr bs sh"),
            (.slovenian, "sl"),
            (.lithuanian, "lt"),
            (.latvian, "lv prg"),
            (.romanian, "ro mo"),
            (.arabic, "ar ars"),
            (.irish, "ga"),
            (.welsh, "cy"),
            (.maltese, "mt"),
            (.hebrew, "he iw"),
        ]
        for (rule, codes) in groups {
            for code in codes.split(separator: " ") { rules[String(code)] = rule }
        }
        return rules
    }()
}

/// A `.stringsdict` entry: its format with `%#@name@` variables, and each variable's forms by plural category.
struct PluralFormat: Equatable {
    var format: String
    var variables: [String: [String: String]]
    /// The language whose rules pick the forms (the `.lproj` the entry came from).
    var language: String

    init?(entry: [String: Any], language: String) {
        guard let format = entry["NSStringLocalizedFormatKey"] as? String else { return nil }
        var variables: [String: [String: String]] = [:]
        for (name, value) in entry {
            guard let spec = value as? [String: Any], spec["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType"
            else { continue }
            variables[name] = spec.compactMapValues { $0 as? String }
        }
        self.format = format
        self.variables = variables
        self.language = language
    }

    init(format: String, variables: [String: [String: String]], language: String) {
        self.format = format
        self.variables = variables
        self.language = language
    }

    /// The format with each variable replaced by its form for the count in its argument (`count(index)`, nil: "other").
    /// Forms that use their number once keep the arguments in order; otherwise every specifier is numbered (`%2$@`),
    /// so a form without its number ("a server") doesn't shift the arguments after it.
    func resolved(count: (Int) -> Int64?) -> String {
        let outer = Spec.parse(format)
        var pieces: [(String, Int?, String)] = []  // (literal, argument, conversion)
        var keepsOrder = true
        for piece in outer {
            switch piece {
            case .literal(let text): pieces.append((text, nil, ""))
            case .spec(let index, let conversion, let positional):
                if positional { keepsOrder = false }
                pieces.append(("", index, conversion))
            case .variable(let index, let name, let positional):
                if positional { keepsOrder = false }
                let form = self.form(name, count: count(index))
                let inner = Spec.parse(form)
                if inner.filter(\.isSpec).count != 1 { keepsOrder = false }
                for part in inner {
                    switch part {
                    case .literal(let text): pieces.append((text, nil, ""))
                    // A form's specifiers stand for its variable's argument.
                    case .spec(_, let conversion, _): pieces.append(("", index, conversion))
                    // A variable inside a form isn't supported: its number stands there.
                    case .variable: pieces.append(("", index, "lld"))
                    }
                }
            }
        }
        var result = ""
        for (literal, index, conversion) in pieces {
            guard let index else { result += literal; continue }
            result += keepsOrder ? "%\(conversion)" : "%\(index + 1)$\(conversion)"
        }
        return result
    }

    private func form(_ name: String, count: Int64?) -> String {
        guard let forms = variables[name] else { return "" }
        guard let count else { return forms["other"] ?? "" }
        // As Apple's Foundation: a "zero" form is used for 0 in every language.
        if count == 0, let zero = forms["zero"] { return zero }
        return forms[PluralRules.category(count, language: language)] ?? forms["other"] ?? ""
    }

    /// A printf format split into text and specifiers, each with the argument it reads.
    enum Spec {
        case literal(String)
        /// A specifier (its conversion without `%` and position, e.g. "lld", "@", ".2f").
        case spec(index: Int, conversion: String, positional: Bool)
        /// `%#@name@`.
        case variable(index: Int, name: String, positional: Bool)

        var isSpec: Bool {
            if case .literal = self { return false }
            return true
        }

        static func parse(_ format: String) -> [Spec] {
            var result: [Spec] = []
            var literal = ""
            var next = 0
            let scalars = Array(format.unicodeScalars)
            var i = 0
            func flush() {
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
            }
            while i < scalars.count {
                let scalar = scalars[i]
                guard scalar == "%", i + 1 < scalars.count else {
                    literal.unicodeScalars.append(scalar)
                    i += 1
                    continue
                }
                if scalars[i + 1] == "%" {
                    literal += "%%"
                    i += 2
                    continue
                }
                var j = i + 1
                // `N$`: an explicit argument.
                var position: Int?
                var digits = ""
                var k = j
                while k < scalars.count, ("0"..."9").contains(scalars[k]) { digits.unicodeScalars.append(scalars[k]); k += 1 }
                if !digits.isEmpty, k < scalars.count, scalars[k] == "$", let value = Int(digits), value > 0 {
                    position = value - 1
                    j = k + 1
                }
                let index = position ?? next
                if position == nil { next += 1 }
                if j + 1 < scalars.count, scalars[j] == "#", scalars[j + 1] == "@" {
                    var name = ""
                    var m = j + 2
                    while m < scalars.count, scalars[m] != "@" { name.unicodeScalars.append(scalars[m]); m += 1 }
                    flush()
                    result.append(.variable(index: index, name: name, positional: position != nil))
                    i = min(m + 1, scalars.count)
                    continue
                }
                // Flags, width, precision and length up to the conversion character.
                var conversion = ""
                var m = j
                while m < scalars.count {
                    let c = scalars[m]
                    conversion.unicodeScalars.append(c)
                    m += 1
                    if "@dDiuUxXoOfFeEgGaAcCsSp".unicodeScalars.contains(c) { break }
                }
                flush()
                result.append(.spec(index: index, conversion: conversion, positional: position != nil))
                i = m
            }
            flush()
            return result
        }
    }
}

/// The `.stringsdict` tables in bundles, read once each.
enum PluralTables {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tables: [String: [String: Any]?] = [:]

    /// `key`'s plural entry in `bundle`: in the bundle itself when it is an `.lproj`, else in its `.lproj` for the
    /// first of `languages` that has the table, then English's.
    static func format(in bundle: Bundle, key: String, table: String?, languages: [String]) -> PluralFormat? {
        let name = "\(table ?? "Localizable").stringsdict"
        let root = bundle.bundleURL
        if root.pathExtension == "lproj" {
            let language = root.deletingPathExtension().lastPathComponent
            return entry(root.appendingPathComponent(name), key: key, language: language)
        }
        var seen = Set<String>()
        for language in languages + ["en"] where seen.insert(language).inserted {
            let url = root.appendingPathComponent("\(language).lproj").appendingPathComponent(name)
            guard let dictionary = load(url) else { continue }
            // English's table too: Foundation's own lookup would read it next, and stop the app on a key it holds.
            guard let entry = dictionary[key] as? [String: Any] else { continue }
            return PluralFormat(entry: entry, language: language)
        }
        return nil
    }

    private static func entry(_ url: URL, key: String, language: String) -> PluralFormat? {
        guard let entry = load(url)?[key] as? [String: Any] else { return nil }
        return PluralFormat(entry: entry, language: language)
    }

    private static func load(_ url: URL) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tables[url.path] { return cached }
        var table: [String: Any]?
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            table = plist as? [String: Any]
        }
        tables[url.path] = .some(table)
        return table
    }

    /// Forgets the tables read (tests; a language pack replaced on disk keeps its new folder's paths).
    static func forget() {
        lock.lock()
        tables.removeAll()
        lock.unlock()
    }
}
