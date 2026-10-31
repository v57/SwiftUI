import Foundation

/// The app's locale where Foundation doesn't follow the user: off Apple platforms swift-foundation's `Locale.current`
/// is always `en_001` and `Locale.preferredLanguages` `["en-001"]`, whatever the system's language. The umbrella
/// module sets it at launch (`AppLanguage`: the system's language, or the one the user picked in the app); SwiftUI then
/// formats with it (the environment's default `locale` and `calendar`) and looks texts up in its language's `.lproj`.
/// Nil on Apple platforms, where Foundation's locale is the user's.
public enum _AppLocale {
    nonisolated(unsafe) public private(set) static var locale: Locale?
    /// `.lproj` names to look for, best first ("pt-BR", "pt_BR", "pt").
    nonisolated(unsafe) static var lprojNames: [String] = []

    /// Sets the app's locale from an identifier ("de_DE", "zh-Hans-CN"). Call before any view resolves: the
    /// environment's defaults are read once.
    public static func set(identifier: String) {
        locale = Locale(identifier: identifier)
        let parts = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else { return }
        var names: [String] = []
        if parts.count > 1 {
            names.append(([language] + parts.dropFirst()).joined(separator: "-"))
            names.append("\(language)-\(parts[1])")
            names.append("\(language)_\(parts[1])")
        }
        names.append(language)
        var seen = Set<String>()
        lprojNames = names.filter { seen.insert($0).inserted }
    }

    /// Back to Foundation's locale (tests).
    static func clear() {
        locale = nil
        lprojNames = []
        lock.lock()
        bundles.removeAll()
        lock.unlock()
    }

    /// The locale to format with: the app's, else Foundation's.
    static var current: Locale { locale ?? .current }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundles: [String: Bundle?] = [:]

    /// The `.lproj` bundle in `bundle` for the app's language, or nil (no app locale, or no such folder: the bundle's
    /// own lookup then picks the development language).
    static func localizedBundle(_ bundle: Bundle) -> Bundle? {
        guard locale != nil, !lprojNames.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[bundle.bundlePath] { return cached }
        let found = lprojNames.lazy.compactMap { bundle.path(forResource: $0, ofType: "lproj") }.first.flatMap(Bundle.init(path:))
        bundles[bundle.bundlePath] = found
        return found
    }

    /// `key` translated into the app's language when its `.lproj` has it, else the bundle's own lookup.
    static func localizedString(_ bundle: Bundle, key: String, table: String?) -> String {
        if let localized = localizedBundle(bundle) {
            let missing = "\u{0}missing"
            let translated = localized.localizedString(forKey: key, value: missing, table: table)
            if translated != missing { return translated }
        }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
}
