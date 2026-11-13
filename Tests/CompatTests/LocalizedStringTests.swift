#if !canImport(ObjectiveC)
import Foundation
@testable import SwiftUIPortability
import Testing

/// `String(localized:)` off Apple platforms: Foundation's keys, a lookup through `_StringLocalization`, formatting.
@Suite(.serialized)
struct LocalizedStringTests {
    @Test func keysMatchFoundation() {
        let name = "Code", count = 3, size: UInt = 7, ratio = 0.5
        let value: String.LocalizationValue = "Open \(name): \(count) files, \(size) MB, \(ratio), 100%"
        #expect(value.key == "Open %@: %lld files, %llu MB, %lf, 100%%")
        let plain: String.LocalizationValue = "100% done"
        #expect(plain.key == "100% done")
    }

    @Test func untranslatedFormats() {
        let name = "Code", count = 3
        #expect(String(localized: "Open \(name) (\(count))") == "Open Code (3)")
        #expect(String(localized: "100% done") == "100% done")
        #expect(String(localized: "Half \(0.5, specifier: "%.1f") of 100%") == "Half 0.5 of 100%")
        #expect(String(localized: "greeting.key", defaultValue: "Hello \(name)") == "Hello Code")
    }

    @Test func lookupTranslates() {
        _StringLocalization.lookup = { _, key, _, _ in
            switch key {
            case "Open %@ (%lld)": return "%2$lld × %1$@ öffnen"
            case "greeting.key": return "Hallo %@"
            default: return key
            }
        }
        defer { _StringLocalization.lookup = nil }
        let name = "Code", count = 3
        #expect(String(localized: "Open \(name) (\(count))") == "3 × Code öffnen")
        #expect(String(localized: "greeting.key", defaultValue: "Hello \(name)") == "Hallo Code")
        #expect(String(localized: "Untranslated") == "Untranslated")
    }
}
#endif
