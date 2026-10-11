import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

extension EnvironmentValues {
    @Entry var macroTestTitle: String = "default title"
    @Entry var macroTestCount: Int = 3
    @Entry var macroTestFlag = true
}

private struct MacroReader: View {
    @Environment(\.macroTestTitle) private var title
    @Environment(\.macroTestCount) private var count
    var body: some View { Text("\(title) \(count)") }
}

#Preview { MacroReader() }

@MainActor
struct MacroTests {
    @Test func entryDeclaresEnvironmentValues() {
        let host = TestHost(VStack {
            MacroReader()
            MacroReader().environment(\.macroTestTitle, "custom").environment(\.macroTestCount, 7)
        })
        #expect(host.texts.contains("default title 3"))
        #expect(host.texts.contains("custom 7"))
    }
}
