import Observation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@Observable
@MainActor
final class ShrinkingRows {
    var rows = ["a", "b", "c"]
    var suffix = ""
}

/// A ForEach whose rows read observable state that changes with the collection: a row can update before the list
/// does, from the shrunk data, where its last position is past the end.
@MainActor
@Suite struct ForEachShrinkTests {
    @Test func rowsUpdatingAsTheCollectionShrinks() {
        let model = ShrinkingRows()
        struct Screen: View {
            let model: ShrinkingRows
            var body: some View {
                VStack {
                    ForEach(model.rows, id: \.self) { row in
                        Text(row + model.suffix)
                    }
                }
            }
        }
        let host = TestHost(Screen(model: model))
        host.flush()
        #expect(host.texts.contains("c"))
        // "c" stays but moves up: its row must not read the old position past the end.
        model.rows.removeFirst()
        model.suffix = "!"
        host.flush()
        #expect(host.texts.contains("b!") && host.texts.contains("c!") && !host.texts.contains("a!"))
    }
}
