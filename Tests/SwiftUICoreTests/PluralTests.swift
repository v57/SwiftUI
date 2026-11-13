import Foundation
import Testing
@testable import _SwiftUICore

/// `.stringsdict` plurals read by SwiftUI off Apple platforms (`Plurals.swift`): the rules against ICU, the forms
/// picked and filled in, and tables found in bundles.
struct PluralTests {
    /// Every language v57 translates into (v57/Localizations' manifest), as its `.lproj` folders are named.
    static let languages = """
        ar ars as az be bg bn bo brx ca chr ckb cs cy da de doi dv el en es et fa fi fil fo fr ga gu haw he hi hr hu hy \
        id is it ja ka kk km kn ko kok ks ku ky lo lt lv mai mi mk ml mn mni mr ms mt my nb ne nl nn or pa pl ps pt-BR \
        pt_PT ro ru sa sat sd si sk sl sq sr sv sw ta te tg th tk to tr ug uk ur vi yue zh-Hans
        """.split(separator: " ").map(String.init)

    static let counts: [Int64] = Array(0...250) + [1000, 1001, 1002, 1011, 1_000_000, 2_000_000, 1_000_001, 10_000_000]

    #if canImport(Darwin)
    /// Each language's category for every count, as macOS's ICU gives it (its CLDR data).
    @Test func rulesMatchICU() throws {
        guard let icu = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW),
              let open = dlsym(icu, "uplrules_open"), let select = dlsym(icu, "uplrules_select"),
              let close = dlsym(icu, "uplrules_close")
        else { Issue.record("no ICU"); return }
        typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> OpaquePointer?
        typealias Select = @convention(c) (OpaquePointer, Double, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Int32
        typealias Close = @convention(c) (OpaquePointer) -> Void
        let openRules = unsafeBitCast(open, to: Open.self)
        let selectRule = unsafeBitCast(select, to: Select.self)
        let closeRules = unsafeBitCast(close, to: Close.self)
        var mismatches: [String] = []
        for language in Self.languages {
            var status: Int32 = 0
            let locale = language.replacingOccurrences(of: "-", with: "_")
            guard let rules = openRules(locale, &status), status <= 0 else { Issue.record("ICU: \(language)"); continue }
            defer { closeRules(rules) }
            var wrong: [String] = []
            for count in Self.counts {
                var buffer = [UInt16](repeating: 0, count: 16)
                var status: Int32 = 0
                let length = selectRule(rules, Double(count), &buffer, 16, &status)
                let expected = String(decoding: buffer.prefix(Int(max(length, 0))), as: UTF16.self)
                let actual = PluralRules.category(count, language: language)
                if actual != expected { wrong.append("\(count): \(actual), ICU \(expected)") }
            }
            if !wrong.isEmpty { mismatches.append("\(language): " + wrong.prefix(4).joined(separator: "; ")) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }
    #endif

    @Test func picksTheFormForTheCount() {
        let english = PluralFormat(
            format: "%#@servers@", variables: ["servers": ["one": "%lld server", "other": "%lld servers"]], language: "en")
        #expect(english.resolved { _ in 1 } == "%lld server")
        #expect(english.resolved { _ in 2 } == "%lld servers")
        #expect(english.resolved { _ in nil } == "%lld servers")
        let russian = PluralFormat(
            format: "%#@n@",
            variables: ["n": ["one": "%lld сервер", "few": "%lld сервера", "many": "%lld серверов", "other": "%lld сервера"]],
            language: "ru")
        #expect(russian.resolved { _ in 21 } == "%lld сервер")
        #expect(russian.resolved { _ in 3 } == "%lld сервера")
        #expect(russian.resolved { _ in 11 } == "%lld серверов")
    }

    @Test func keepsTheOtherArguments() {
        let format = PluralFormat(
            format: "%@ has %#@files@ in %@",
            variables: ["files": ["one": "%lld file", "other": "%lld files"]], language: "en")
        #expect(format.resolved { $0 == 1 ? 1 : nil } == "%@ has %lld file in %@")
        #expect(String(format: format.resolved { $0 == 1 ? 2 : nil }, "Code", 2 as Int64, "src") == "Code has 2 files in src")
    }

    @Test func formWithoutItsNumberNumbersTheArguments() {
        let format = PluralFormat(
            format: "%#@files@ in %@",
            variables: ["files": ["one": "a file", "other": "%lld files"]], language: "en")
        let one = format.resolved { $0 == 0 ? 1 : nil }
        #expect(one == "a file in %2$@")
        #expect(String(format: one, 1 as Int64, "src") == "a file in src")
        #expect(String(format: format.resolved { $0 == 0 ? 3 : nil }, 3 as Int64, "src") == "3 files in src")
    }

    @Test func zeroFormForZeroInEveryLanguage() {
        let format = PluralFormat(
            format: "%#@n@", variables: ["n": ["zero": "No servers", "one": "%lld server", "other": "%lld servers"]],
            language: "en")
        #expect(format.resolved { _ in 0 } == "No servers")
        #expect(format.resolved { _ in 1 } == "%lld server")
    }

    @Test func positionalVariables() {
        let format = PluralFormat(
            format: "%2$@: %1$#@n@", variables: ["n": ["one": "%lld item", "other": "%lld items"]], language: "en")
        #expect(String(format: format.resolved { $0 == 0 ? 5 : nil }, 5 as Int64, "Cart") == "Cart: 5 items")
    }

    @Test func readsTablesInBundles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plurals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let table: [String: Any] = [
            "%lld servers": [
                "NSStringLocalizedFormatKey": "%#@n@",
                "n": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                    "one": "%lld server", "other": "%lld servers",
                ],
            ]
        ]
        let english = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
            .write(to: english.appendingPathComponent("Localizable.stringsdict"))
        PluralTables.forget()
        let bundle = try #require(Bundle(url: root))
        let found = PluralTables.format(in: bundle, key: "%lld servers", table: nil, languages: ["de"])
        #expect(found?.language == "en")
        #expect(found?.resolved { _ in 1 } == "%lld server")
        #expect(PluralTables.format(in: bundle, key: "%lld clients", table: nil, languages: ["de"]) == nil)
        // An `.lproj` bundle (the app's own language folder) answers for its language.
        let lproj = try #require(Bundle(url: english))
        #expect(PluralTables.format(in: lproj, key: "%lld servers", table: nil, languages: [])?.language == "en")
    }
}
