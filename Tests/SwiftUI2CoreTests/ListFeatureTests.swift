import Foundation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class FruitListModel {
    var items = ["Apple", "Banana", "Cherry"]
    var selection: String?
    var log: [String] = []
}

@MainActor
@Suite(.serialized)
struct ListFeatureTests {
    @Test func badgesInsetsAndSeparators() throws {
        let host = TestHost(
            List {
                Text("Inbox").badge(3)
                Text("Custom").listRowInsets(EdgeInsets(top: 0, leading: 40, bottom: 0, trailing: 0))
                Text("Plain").listRowSeparator(.hidden)
                Text("Last")
            },
            size: CGSize(width: 300, height: 300)
        )
        #expect(host.texts.contains("3"))
        let inbox = try #require(host.view(withText: "Inbox")).absoluteFrame
        let custom = try #require(host.view(withText: "Custom")).absoluteFrame
        #expect(custom.minX - inbox.minX > 20)
        // Two separators by default between 4 rows would be 3; the hidden one removes one.
        let separators = host.allViews.filter { view in
            if case .color = view.content { return view.frame.height == 1 }
            if case .shape(let shape) = view.content { return shape.fill != nil && view.frame.height == 1 }
            return false
        }
        #expect(separators.count == 2)
    }

    @Test func swipeActionsAndDeleteInContextMenu() {
        let model = FruitListModel()
        struct Screen: View {
            let model: FruitListModel
            var body: some View {
                List {
                    ForEach(model.items, id: \.self) { item in
                        Text(item)
                            .swipeActions { Button("Pin") { model.log.append("pin \(item)") } }
                            .deleteDisabled(item == "Banana")
                    }
                    .onDelete { offsets in model.items.remove(atOffsets: offsets) }
                }
            }
        }
        let host = TestHost(Screen(model: model))
        host.secondaryClick("Apple")
        host.tap("Pin")
        host.finishAnimations()
        #expect(model.log == ["pin Apple"])
        host.secondaryClick("Apple")
        host.tap("Delete")
        host.finishAnimations()
        #expect(model.items == ["Banana", "Cherry"])
        host.secondaryClick("Banana")
        #expect(!host.texts.contains("Delete"))
    }

    @Test func onMoveMakesRowsDraggable() {
        let model = FruitListModel()
        struct Screen: View {
            let model: FruitListModel
            var body: some View {
                List {
                    ForEach(model.items, id: \.self) { Text($0) }
                        .onMove { model.items.move(fromOffsets: $0, toOffset: $1) }
                }
            }
        }
        let host = TestHost(Screen(model: model))
        let draggable = host.allViews.filter { $0.node?.actions.dragItem != nil }
        let droppable = host.allViews.filter { $0.node?.actions.drop != nil }
        #expect(draggable.count == 3 && droppable.count == 3)
    }

    @Test func typeSelectSelectsRows() {
        let model = FruitListModel()
        struct Screen: View {
            @Bindable var model: FruitListModel
            var body: some View {
                List(selection: $model.selection) {
                    ForEach(model.items, id: \.self) { item in
                        Text(item).typeSelectEquivalent(item)
                    }
                }
            }
        }
        let host = TestHost(Screen(model: model))
        _ = host.graph.handleKeyPress(KeyPress(key: KeyEquivalent("c"), characters: "c", modifiers: [], phase: .down))
        host.flush()
        #expect(model.selection == "Cherry")
    }
}
