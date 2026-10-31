#if os(Windows) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import WinSDK
#endif
import _SwiftUICore

/// Formats for the languages a release's ICU leaves out. A release build can ship ICU with only the app's own
/// languages (Windows: build-app.ps1, 36 → 8 MB for English), and dates, numbers, lists and names in other languages
/// then come out in English. A language pack holds one language's ICU data (0.1–4 MB), from the SwiftUI repository's
/// GitHub release `icu-<ICU version>`; ICU merges it with its built-in data when it's in the folder ICU reads, so it
/// applies from the next launch. Packs are shared by every app on the machine that uses them
/// (`%LOCALAPPDATA%\SwiftUI\ICU\<version>\<language>`, `~/.local/share/swiftui/icu/<version>/<language>`).
///
/// At launch, `App.main()` points ICU at the pack of the app's language (`AppLanguage`) if one is downloaded. Otherwise,
/// when the build lacks that language, the app asks once whether to download it: nothing is downloaded without a yes.
/// `offer()` asks again (for a Settings button), `download(_:)` downloads without asking.
@MainActor
public enum ICULanguagePack {
    /// This build's ICU when it holds only some languages: its version and those languages (Info.plist's
    /// SwiftUIICUVersion and SwiftUIICULanguages, written by build-app.ps1). Nil for an ICU with every language.
    static let build: (version: String, languages: Set<String>)? = {
        guard let info = Bundle.main.infoDictionary, let version = info["SwiftUIICUVersion"] as? String,
              let languages = info["SwiftUIICULanguages"] as? String else { return nil }
        return (version, Set(languages.split(separator: " ").map(String.init)))
    }()

    /// The language whose pack ICU uses in this process (set at launch).
    public private(set) static var active: String?

    /// The app's language when this build's ICU doesn't have it ("de"), else nil.
    public static var missingLanguage: String? {
        let language = AppLanguage.languageCode
        guard let build, !build.languages.contains(language) else { return nil }
        return language
    }

    /// Whether the pack for `language` is downloaded.
    public static func isDownloaded(_ language: String) -> Bool {
        guard let build else { return false }
        return FileManager.default.fileExists(atPath: file(for: language, version: build.version).path)
    }

    /// Called by `AppLanguage.launch()` before anything can load ICU data (ICU reads its data folder once): uses the
    /// pack of the app's language, else asks once, after launch, whether to download it.
    static func launch(language: String) {
        guard let build, !build.languages.contains(language) else { return }
        if isDownloaded(language) {
            setDataDirectory(file(for: language, version: build.version).deletingLastPathComponent().path)
            active = language
            return
        }
        let key = "SwiftUIICULanguagePackOffered.\(language)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task { @MainActor in
            // After the app's first window: the question comes from the app, not before it.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            UserDefaults.standard.set(true, forKey: key)
            offer()
        }
    }

    private static var offerWindow: HostingWindow?

    /// Shows the window that offers the pack of the app's language (when the build lacks it).
    public static func offer() {
        guard let language = missingLanguage else { return }
        if let offerWindow {
            offerWindow.show()
            return
        }
        let window = HostingWindow(title: "Language", defaultSize: CGSize(width: 460, height: 210)) {
            LanguagePackOffer(language: language) { offerWindow?.close() }
        }
        window.onClose = { offerWindow = nil }
        offerWindow = window
        window.show()
    }

    /// Downloads the pack for `language` (from SWIFTUI_ICU_PACKS_URL instead of GitHub when set, for testing).
    public static func download(_ language: String) async throws {
        guard let build else { throw PackError.notNeeded }
        let base = ProcessInfo.processInfo.environment["SWIFTUI_ICU_PACKS_URL"]
            ?? "https://github.com/v57/SwiftUI/releases/download/icu-\(build.version)"
        guard let url = URL(string: "\(base)/icudt\(build.version)l-\(language).dat") else { throw PackError.notNeeded }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 404 ? PackError.noPack(language) : PackError.server(status) }
        // An ICU data package: its header size, then the magic 0xDA27.
        guard data.count > 4, data[data.startIndex + 2] == 0xDA, data[data.startIndex + 3] == 0x27 else {
            throw PackError.server(status)
        }
        let target = file(for: language, version: build.version)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    enum PackError: LocalizedError {
        case notNeeded, noPack(String), server(Int)
        var errorDescription: String? {
            switch self {
            case .notNeeded: return "This app has every language's formats."
            case .noPack(let language): return "There are no formats for \(ICULanguagePack.name(of: language)) to download."
            case .server(let status): return "The download failed (\(status == 0 ? "no response" : "HTTP \(status)"))."
            }
        }
    }

    /// The language's English name ("German"), from the built-in English data.
    nonisolated static func name(of language: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
    }

    /// The pack's file: ICU looks for its data package, icudt<version>l.dat, in the folder it's pointed at.
    static func file(for language: String, version: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        #if os(Windows)
        let base = URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? NSTemporaryDirectory())
            .appendingPathComponent("SwiftUI").appendingPathComponent("ICU")
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let base = data.appendingPathComponent("swiftui").appendingPathComponent("icu")
        #endif
        return base.appendingPathComponent(version).appendingPathComponent(language)
            .appendingPathComponent("icudt\(version)l.dat")
    }

    private static func setDataDirectory(_ path: String) {
        #if os(Windows)
        // ICU's u_setDataDirectory, exported by Foundation's ICU DLL under its swift_ prefix.
        typealias SetDataDirectory = @convention(c) (UnsafePointer<CChar>?) -> Void
        let module = "_FoundationICU.dll".withCString(encodedAs: UTF16.self) { GetModuleHandleW($0) }
        if let module, let function = GetProcAddress(module, "swift_u_setDataDirectory") {
            unsafeBitCast(function, to: SetDataDirectory.self)(path)
            return
        }
        _ = _putenv_s("ICU_DATA", path)
        #else
        // ICU reads ICU_DATA when nothing set its folder (Linux links ICU statically, without exporting it).
        setenv("ICU_DATA", path, 1)
        #endif
    }
}

/// The question: download the user's language's formats?
private struct LanguagePackOffer: View {
    let language: String
    let close: () -> Void
    @State private var phase = Phase.asking

    enum Phase: Equatable { case asking, downloading, done, failed(String) }

    private var languageName: String { ICULanguagePack.name(of: language) }
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "this app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(languageName) formats").font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                switch phase {
                case .asking:
                    Button("Not Now") { close() }
                    Button("Download") { start() }.keyboardShortcut(.defaultAction)
                case .downloading:
                    ProgressView().controlSize(.small)
                    Button("Download") {}.disabled(true)
                case .done, .failed:
                    Button("Close") { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 170)
    }

    private var message: String {
        switch phase {
        case .asking, .downloading:
            return "\(appName) shows dates, numbers and names in English: it has the formats of its own languages only. "
                + "Download the \(languageName) formats (up to 4 MB) from GitHub?"
        case .done:
            return "The \(languageName) formats are downloaded. They apply the next time you open \(appName)."
        case .failed(let reason):
            return reason
        }
    }

    private func start() {
        phase = .downloading
        Task { @MainActor in
            do {
                try await ICULanguagePack.download(language)
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
