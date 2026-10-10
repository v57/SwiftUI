import Foundation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

extension ContainerValues {
    @Entry var isHighlighted: Bool = false
}

struct Numbered<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    HStack {
                        Text("\(index + 1).")
                        subview
                        if subview.containerValues.isHighlighted { Text("*") }
                    }
                }
                Text("\(subviews.count) items")
            }
        }
    }
}

struct Sectioned<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack {
            ForEach(sections: content) { section in
                Text("[\(section.content.count)]")
                section.header
                ForEach(subviews: section.content) { $0 }
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct SubviewsTests {
    @Test func customContainerSeesSubviewsAndContainerValues() {
        let host = TestHost(Numbered {
            Text("a")
            ForEach(["b", "c"], id: \.self) { Text($0) }
            Text("d").containerValue(\.isHighlighted, true)
        })
        #expect(host.texts == ["1.", "a", "2.", "b", "3.", "c", "4.", "d", "*", "4 items"])
    }

    @Test func sectionsSplitHeadersAndContent() {
        let host = TestHost(Sectioned {
            Section("Fruit") { Text("apple"); Text("pear") }
            Section("Veg") { Text("leek") }
        })
        #expect(host.texts == ["[2]", "Fruit", "apple", "pear", "[1]", "Veg", "leek"])
    }

    @Test func asyncImageLoadsLocalFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftui2-async-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = TestHost(
            AsyncImage(url: url) { phase in
                if phase.image != nil { Text("loaded") } else if phase.error != nil { Text("failed") } else { Text("loading") }
            }
            .environment(\._imageDecoder, ImageDecoder { data, _ in data.count == 3 ? Image(systemName: "star") : nil })
        )
        #expect(host.texts == ["loading"])
        for _ in 0..<50 where host.texts != ["loaded"] {
            try await Task.sleep(for: .milliseconds(10))
            host.flush()
        }
        #expect(host.texts == ["loaded"])
    }
}
