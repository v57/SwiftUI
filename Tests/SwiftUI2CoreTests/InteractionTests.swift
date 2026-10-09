import Foundation
import Observation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class InteractionModel {
    var flavor = "Vanilla"
    var mode = 0
    var log: [String] = []
    var tab = 0
    var selection: Int?
    var offset: CGSize = .zero
    var path: [Int] = []
}

@MainActor
@Suite(.serialized)
struct InteractionTests {
    @Test func sheetPresentsAndDismisses() {
        struct Screen: View {
            @State var shown = false
            var body: some View {
                Button("Open") { shown = true }
                    .sheet(isPresented: $shown) { SheetBody() }
            }
        }
        struct SheetBody: View {
            @Environment(\.dismiss) var dismiss
            var body: some View {
                VStack {
                    Text("In sheet")
                    Button("Close") { dismiss() }
                }
            }
        }
        let host = TestHost(Screen())
        #expect(!host.texts.contains("In sheet"))
        host.tap("Open")
        #expect(host.texts.contains("In sheet"))
        host.tap("Close")
        host.finishAnimations()
        #expect(!host.texts.contains("In sheet"))
        host.tap("Open")
        host.pressEscape()
        host.finishAnimations()
        #expect(!host.texts.contains("In sheet"))
    }

    @Test func alertButtonsRunAndDismiss() {
        struct Screen: View {
            @State var shown = false
            let model: InteractionModel
            var body: some View {
                Button("Ask") { shown = true }
                    .alert("Delete?", isPresented: $shown) {
                        Button("Delete", role: .destructive) { model.log.append("deleted") }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Gone forever")
                    }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("Ask")
        #expect(host.texts.contains("Delete?"))
        #expect(host.texts.contains("Gone forever"))
        host.tap("Delete")
        host.finishAnimations()
        #expect(model.log == ["deleted"])
        #expect(!host.texts.contains("Delete?"))
    }

    @Test func menuPickerSelectsOption() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View {
                Picker("Flavor", selection: $model.flavor) {
                    ForEach(["Vanilla", "Chocolate", "Strawberry"], id: \.self) { Text($0) }
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        // The closed picker shows only the selected option.
        #expect(host.texts.filter { $0 == "Chocolate" }.isEmpty)
        host.tap("Vanilla")
        #expect(host.texts.contains("Chocolate")) // menu open
        host.tap("Chocolate")
        host.finishAnimations()
        #expect(model.flavor == "Chocolate")
        #expect(!host.texts.contains("Strawberry")) // menu closed
        #expect(host.texts.contains("Chocolate"))
    }

    @Test func segmentedAndRadioPickers() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View {
                VStack {
                    Picker("Mode", selection: $model.mode) {
                        Text("One").tag(0)
                        Text("Two").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Picker("Radio", selection: $model.mode) {
                        Text("First").tag(0)
                        Text("Second").tag(1)
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("Two")
        #expect(model.mode == 1)
        host.tap("First")
        #expect(model.mode == 0)
    }

    @Test func menuButtonsRunActions() {
        struct Screen: View {
            let model: InteractionModel
            var body: some View {
                Menu("Actions") {
                    Button("Copy") { model.log.append("copy") }
                    Button("Paste") { model.log.append("paste") }
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("Actions")
        host.tap("Paste")
        host.finishAnimations()
        #expect(model.log == ["paste"])
        #expect(!host.texts.contains("Copy"))
    }

    @Test func contextMenu() {
        struct Screen: View {
            let model: InteractionModel
            var body: some View {
                Text("Row").contextMenu { Button("Remove") { model.log.append("removed") } }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.secondaryClick("Row")
        host.tap("Remove")
        #expect(model.log == ["removed"])
    }

    @Test func navigationStackPushAndPop() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View {
                NavigationStack(path: $model.path) {
                    VStack {
                        NavigationLink("Go to 7", value: 7)
                    }
                    .navigationDestination(for: Int.self) { value in
                        Text("Detail \(value)").navigationTitle("Number \(value)")
                    }
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("Go to 7")
        #expect(model.path == [7])
        #expect(host.texts.contains("Detail 7"))
        // macOS: the title goes to the window title, the back button to the window toolbar.
        #expect(host.graph.navigationTitle == "Number 7")
        let back = host.graph.windowToolbar.items.first { $0.placement == .navigation }?.button
        #expect(back?.systemImage == "chevron.backward")
        back?.action()
        host.flush()
        #expect(model.path.isEmpty)
        #expect(host.graph.windowToolbar.items.isEmpty)
    }

    @Test func tabViewSwitchesContent() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View {
                TabView(selection: $model.tab) {
                    Text("Home content").tabItem { Text("Home") }.tag(0)
                    Text("Settings content").tabItem { Text("Settings") }.tag(1)
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        #expect(host.texts.contains("Home content"))
        #expect(!host.texts.contains("Settings content"))
        host.tap("Settings")
        #expect(model.tab == 1)
        #expect(host.texts.contains("Settings content"))
        #expect(!host.texts.contains("Home content"))
    }

    @Test func listSelection() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View {
                List(selection: $model.selection) {
                    ForEach(1...3, id: \.self) { Text("Item \($0)") }
                }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("Item 2")
        #expect(model.selection == 2)
    }

    @Test func dragGestureUpdatesState() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            @GestureState var dragging = false
            var body: some View {
                Text(dragging ? "dragging" : "idle")
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .updating($dragging) { _, state, _ in state = true }
                            .onEnded { model.offset = $0.translation }
                    )
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.drag("idle", by: CGSize(width: 40, height: 10))
        #expect(model.offset == CGSize(width: 40, height: 10))
        #expect(host.texts.contains("idle")) // @GestureState resets when the gesture ends
    }

    @Test func tapGestureWithLocation() {
        struct Screen: View {
            let model: InteractionModel
            var body: some View {
                Color.blue.frame(width: 50, height: 50)
                    .overlay(Text("target"))
                    .onTapGesture { location in model.log.append("tap \(Int(location.x))") }
            }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        host.tap("target")
        #expect(model.log.count == 1)
    }

    @Test func controlsBoundToObservableModelsUpdate() {
        struct Screen: View {
            @Bindable var model: InteractionModel
            var body: some View { TextField("Flavor", text: $model.flavor) }
        }
        let model = InteractionModel()
        let host = TestHost(Screen(model: model))
        model.flavor = "Mango"
        host.flush()
        let field = host.allViews.first { if case .textField = $0.content { return true }; return false }
        guard case .textField(let resolved)? = field?.content else { Issue.record("no field"); return }
        #expect(resolved.text == "Mango")
    }

    @Test func preferencesReachAncestors() {
        struct Width: PreferenceKey {
            static let defaultValue: CGFloat = 0
            static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
        }
        struct Screen: View {
            @State var width: CGFloat = 0
            var body: some View {
                VStack {
                    VStack {
                        ForEach(["a", "bbbbbb"], id: \.self) { label in
                            Text(label).background(GeometryReader { proxy in
                                Color.clear.preference(key: Width.self, value: proxy.size.width)
                            })
                        }
                    }
                    .onPreferenceChange(Width.self) { width = $0 }
                    Text("max \(Int(width))")
                }
            }
        }
        let host = TestHost(Screen())
        #expect(host.texts.contains("max 39")) // 6 chars × 6.5pt, rounded up
    }
}
