import Foundation
#if !canImport(ObjectiveC)
import SwiftUIPortability
#endif

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
        #if !canImport(ObjectiveC)
        // `String(localized:)` (SwiftUIPortability) translates and formats as texts do.
        _StringLocalization.locale = locale
        _StringLocalization.lookup = { localizedString($0, key: $1, table: $2) }
        #endif
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
        #if !canImport(ObjectiveC)
        _StringLocalization.locale = nil
        _StringLocalization.lookup = nil
        #endif
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

    nonisolated(unsafe) private static var packBundles: [Bundle] = []

    /// Bundles of a downloaded language pack, asked before the main bundle's own tables, best first (PlatformLanguages:
    /// each holds the app's language's `.lproj`). Texts already shown keep their strings until they're rebuilt.
    @MainActor public static func _setPackBundles(_ bundles: [Bundle]) {
        lock.lock()
        packBundles = bundles
        lock.unlock()
        LocalizedTextResolver.forgetTranslations()
    }

    /// `key` translated into the app's language: from a language pack (main bundle only), else from the bundle's
    /// `.lproj` for that language, else the bundle's own lookup.
    static func localizedString(_ bundle: Bundle, key: String, table: String?) -> String {
        let missing = "\u{0}missing"
        if bundle.bundlePath == Bundle.main.bundlePath {
            lock.lock()
            let packs = packBundles
            lock.unlock()
            for pack in packs {
                let translated = pack.localizedString(forKey: key, value: missing, table: table)
                if translated != missing { return translated }
            }
        }
        if let localized = localizedBundle(bundle) {
            let translated = localized.localizedString(forKey: key, value: missing, table: table)
            if translated != missing { return translated }
        }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }
}
