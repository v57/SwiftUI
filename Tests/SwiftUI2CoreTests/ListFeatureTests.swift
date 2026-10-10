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

    @Test func disclosureGroupsBecomeOutlineRows() throws {
        struct Node: Identifiable { let id: String; var children: [Node]? }
        struct Screen: View {
            @State var expanded = false
            let tree = [Node(id: "Root", children: [Node(id: "Leaf", children: nil)])]
            var body: some View {
                List {
                    Text("Flat")
                    DisclosureGroup("Group", isExpanded: $expanded) { Text("Child") }
                    OutlineGroup(tree, children: \.children) { Text($0.id) }
                }
                .listStyle(.inset)
            }
        }
        let host = TestHost(Screen(), size: CGSize(width: 300, height: 400))
        #expect(!host.texts.contains("Child") && !host.texts.contains("Leaf"))
        // Rows leave room for the disclosure column (25pt from the list edge).
        let flat = try #require(host.view(withText: "Flat")).absoluteFrame
        let group = try #require(host.view(withText: "Group")).absoluteFrame
        #expect(flat.minX == 25 && group.minX == 25)
        // Each disclosure group's chevron is its own button; expanding shows the children as
        // rows one level (13pt) deeper.
        let chevrons = host.allViews.filter { $0.node?.actions.primary != nil && $0.allDescendants.contains { $0.text == nil } }
        #expect(chevrons.count >= 2)
        chevrons[0].node?.actions.primary?()
        host.flush()
        host.finishAnimations()
        let child = try #require(host.view(withText: "Child")).absoluteFrame
        #expect(child.minX == 38)
        #expect(child.minY > group.maxY)
        chevrons[1].node?.actions.primary?()
        host.flush()
        host.finishAnimations()
        #expect(host.texts.contains("Leaf"))
    }

    @Test func sidebarSearchFieldIsTheListsFirstRow() throws {
        struct Screen: View {
            @State var query = ""
            var body: some View {
                VStack {
                    List { Section("Items") { Text("One") } }.listStyle(.sidebar)
                }
                .searchable(text: $query, placement: .sidebar)
            }
        }
        let host = TestHost(Screen(), size: CGSize(width: 300, height: 400))
        // Hosted by the list (10pt inset, 28pt row), so the window toolbar has no search field.
        #expect(host.graph.windowToolbar.items.allSatisfy { $0.search == nil })
        let field = try #require(host.allViews.first { if case .textField = $0.content { true } else { false } })
        let header = try #require(host.view(withText: "Items")).absoluteFrame
        #expect(field.absoluteFrame.minY < header.minY)
        #expect(header.minY - field.absoluteFrame.maxY > 13)
    }

    @Test func toolbarSearchFieldSubmitsSearchActions() {
        @MainActor final class Log { var lines: [String] = [] }
        let log = Log()
        struct Screen: View {
            let log: Log
            @State var query = ""
            @State var name = ""
            var body: some View {
                VStack {
                    TextField("Name", text: $name)
                    Text("query \(query)")
                }
                .searchable(text: $query)
                .onSubmit(of: .search) { log.lines.append("search") }
                .onSubmit { log.lines.append("text") }
            }
        }
        let host = TestHost(Screen(log: log))
        let search = try? #require(host.graph.windowToolbar.items.first { $0.search != nil })
        #expect(search?.search?.prompt == "Search")
        // The toolbar field comes after the window's own fields.
        host.type("ada", intoFieldAt: 1)
        #expect(host.texts.contains("query ada"))
        #expect(host.graph.windowToolbar.items.first { $0.search != nil }?.search?.text == "ada")
        let fields = host.allViews.filter { if case .textField = $0.content { true } else { false } }
        fields[1].node?.actions.submit?()
        fields[0].node?.actions.submit?()
        #expect(log.lines == ["search", "text"])
    }
}
