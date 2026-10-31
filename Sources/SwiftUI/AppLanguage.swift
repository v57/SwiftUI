#if os(Windows) || os(Linux)
import Foundation
#if os(Windows)
import WinSDK
#endif
import _SwiftUICore

/// The app's language off Apple platforms, where Foundation's `Locale.current` is always `en_001`: the system's display
/// language (Windows: the first preferred UI language; Linux: LANGUAGE, LC_ALL, LC_MESSAGES, LANG) with the region of
/// the user's formats, or the language the user picked in the app (`chosen`, kept across launches). `App.main()` sets
/// it before anything runs; SwiftUI formats with it (the environment's `locale` and `calendar`) and shows the app's
/// texts from its `.lproj`. Code that calls Foundation directly (`Date.formatted()`, `String(localized:)`) still gets
/// `en_001`: read `\.locale` instead. A choice applies from the next launch, like the system's own language.
@MainActor
public enum AppLanguage {
    private static let chosenKey = "SwiftUIAppLanguage"

    /// The locale the app runs with ("de_AT", "zh-Hans_CN"), set at launch.
    public private(set) static var identifier = "en"

    /// Its language code ("de", "zh").
    public static var languageCode: String { code(of: identifier) }

    /// The system's locale ("de_AT"), nil when it names none ("C", "POSIX").
    public static let system: String? = detect()

    /// The language the user picked in the app ("de"), nil to follow the system. Applies from the next launch.
    public static var chosen: String? {
        get { UserDefaults.standard.string(forKey: chosenKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: chosenKey) }
    }

    /// The languages to offer: the app's translations, the formats its ICU has, the system's and the chosen one.
    public static var available: [String] {
        var codes = Set(Bundle.main.localizations.filter { $0 != "Base" })
        codes.formUnion(ICULanguagePack.build?.languages ?? [])
        if let system { codes.insert(code(of: system)) }
        if let chosen { codes.insert(chosen) }
        codes.insert(languageCode)
        if codes.isEmpty { codes.insert("en") }
        return codes.sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
    }

    /// The language's name in that language when ICU has its data ("Deutsch"), else in English ("German").
    public static func name(of language: String) -> String {
        let locale = Locale(identifier: language)
        // Without the language's data ICU names it by its code.
        guard let own = locale.localizedString(forLanguageCode: language), own.lowercased() != language else {
            return ICULanguagePack.name(of: language)
        }
        return own.capitalized(with: locale)
    }

    /// Called by `App.main()` first. ICU reads its data folder once, so the language pack is chosen before any
    /// `Locale` is made.
    static func launch() {
        identifier = resolve()
        ICULanguagePack.launch(language: languageCode)
        _AppLocale.set(identifier: identifier)
    }

    /// The chosen language with the system's region ("de" in Austria → "de_AT"), else the system's locale.
    private static func resolve() -> String {
        guard let chosen else { return system ?? "en" }
        guard let region = system.flatMap(region(of:)) else { return chosen }
        return chosen.contains(where: { $0 == "_" || $0 == "-" }) ? chosen : "\(chosen)_\(region)"
    }

    static func code(of identifier: String) -> String {
        String(identifier.prefix { $0.isASCII && $0.isLetter }).lowercased()
    }

    /// The region of "de-AT", "zh-Hans-CN", "es_419": two letters or three digits after the language and script.
    static func region(of identifier: String) -> String? {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" }).dropFirst()
            .first { ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }
            .map { $0.uppercased() }
    }

    /// "de-DE", "de_DE.UTF-8@euro" → language (and script) "de" / "zh_Hans"; "C" and "POSIX" → nil.
    static func language(of name: String) -> String? {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" })
        guard let first = parts.first, first.count >= 2, first.count <= 3, first.allSatisfy({ $0.isASCII && $0.isLetter }),
              first.lowercased() != "c" else { return nil }
        let language = first.lowercased()
        if parts.count > 1, parts[1].count == 4, parts[1].allSatisfy(\.isLetter) {
            return "\(language)_\(parts[1].prefix(1).uppercased())\(parts[1].dropFirst().lowercased())"
        }
        return language
    }

    /// The system's language with the region of its formats.
    static func detect() -> String? {
        #if os(Windows)
        var count: ULONG = 0, size: ULONG = 0
        var display: String?
        // MUI_LANGUAGE_NAME: names ("de-DE"), a double-NUL-terminated list.
        if GetUserPreferredUILanguages(0x8, &count, nil, &size), size > 0 {
            var buffer = [WCHAR](repeating: 0, count: Int(size))
            if GetUserPreferredUILanguages(0x8, &count, &buffer, &size) {
                display = String(decodingCString: buffer, as: UTF16.self)
            }
        }
        var buffer = [WCHAR](repeating: 0, count: Int(LOCALE_NAME_MAX_LENGTH))
        let formats = GetUserDefaultLocaleName(&buffer, Int32(buffer.count)) > 0
            ? String(decodingCString: buffer, as: UTF16.self) : nil
        #else
        let environment = ProcessInfo.processInfo.environment
        func first(_ names: [String]) -> String? {
            names.lazy.compactMap { environment[$0] }.first { !$0.isEmpty && language(of: $0) != nil }
        }
        // LANGUAGE is a list ("de_AT:de:en"); the other variables apply only when it's unset, as in gettext.
        let display = environment["LANGUAGE"]?.split(separator: ":").first.map(String.init).flatMap { language(of: $0) != nil ? $0 : nil }
            ?? first(["LC_ALL", "LC_MESSAGES", "LANG"])
        let formats = first(["LC_ALL", "LC_TIME", "LANG"])
        #endif
        guard let language = (display ?? formats).flatMap(language(of:)) else { return nil }
        guard let region = formats.flatMap(region(of:)) ?? display.flatMap(region(of:)) else { return language }
        return "\(language)_\(region)"
    }
}

/// A picker for the app's language (System or one of `AppLanguage.available`), for an app's settings.
public struct AppLanguagePicker: View {
    @State private var selection = AppLanguage.chosen ?? ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Language", selection: $selection) {
                Text(AppLanguage.system.map { "System (\(AppLanguage.name(of: AppLanguage.code(of: $0))))" } ?? "System")
                    .tag("")
                ForEach(AppLanguage.available, id: \.self) { language in
                    Text(AppLanguage.name(of: language)).tag(language)
                }
            }
            .onChange(of: selection) { _, language in AppLanguage.chosen = language.isEmpty ? nil : language }
            if (selection.isEmpty ? AppLanguage.system.map(AppLanguage.code(of:)) ?? "en" : selection) != AppLanguage.languageCode {
                Text("Applies the next time you open the app.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
