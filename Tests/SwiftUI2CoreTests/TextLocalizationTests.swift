import Foundation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@MainActor
@Suite(.serialized)
struct TextLocalizationTests {
    private func resolved(_ text: Text) -> ResolvedText { text.resolve(in: EnvironmentValues()) }

    @Test func interpolationBuildsFormatKeys() {
        let name = "Ana"
        let key: LocalizedStringKey = "Hello \(name), you have \(3) new · 100%"
        #expect(key.key == "Hello %@, you have %lld new · 100%%")
        #expect(Text(key).plainString == "Hello Ana, you have 3 new · 100%")
        #expect(Text("Pi is \(3.14159, specifier: "%.2f")").plainString == "Pi is 3.14")
        // Non-interpolated keys are not format strings.
        #expect(Text("50% off").plainString == "50% off")
    }

    @Test func literalKeysParseInlineMarkdown() {
        let text = resolved(Text("Hello **World** and *you*"))
        #expect(text.string == "Hello World and you")
        let bold = text.effectiveRuns.first { $0.string == "World" }
        let italic = text.effectiveRuns.first { $0.string == "you" }
        #expect(bold?.font.weight == .bold)
        #expect(italic?.font.italic == true)
        // Verbatim text and String values are not Markdown.
        let raw = "**raw**"
        #expect(Text(raw).plainString == "**raw**")
        #expect(Text(verbatim: "**raw**").plainString == "**raw**")
    }

    @Test func markdownLinksAreLinkRuns() {
        let text = resolved(Text("Read the [docs](https://example.com/docs)."))
        let link = text.effectiveRuns.first { $0.string == "docs" }
        #expect(link?.link == URL(string: "https://example.com/docs"))
        #expect(link?.color == Color.accentColor.resolve(in: EnvironmentValues()))
    }

    @Test func imagesAndTextInterpolateInline() {
        let text = resolved(Text("\(Image(systemName: "star.fill")) Favorites \(Text("now").bold())"))
        #expect(text.effectiveRuns.first?.image?.source == .system("star.fill"))
        #expect(text.effectiveRuns.contains { $0.string == "now" && $0.font.weight == .bold })
        #expect(Text("\(Image(systemName: "star")) Favorites").plainString == " Favorites")
    }

    @Test func keysAreTranslatedFromTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID().uuidString).bundle")
        let lproj = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try "\"Hello %@\" = \"Bonjour %@\";\n\"Plain\" = \"Simple\";\n".write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try #require(Bundle(path: root.path))
        let name = "Ana"
        #expect(Text("Hello \(name)", bundle: bundle).plainString == "Bonjour Ana")
        #expect(Text("Plain", bundle: bundle).plainString == "Simple")
        #expect(Text("Missing", bundle: bundle).plainString == "Missing")
    }

    @Test func textViewRendersLocalizedRuns() {
        let host = TestHost(Text("Tap **here**"))
        #expect(host.texts.contains("Tap here"))
    }
}
