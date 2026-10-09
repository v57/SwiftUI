import Foundation
import Observation
import Testing
import SwiftUI2Core
import SwiftUI2Headless

struct Highlight: ViewModifier {
    @State private var taps = 0
    func body(content: Content) -> some View {
        let _ = Counter.hit("Highlight")
        VStack {
            content
            Button("highlight \(taps)") { taps += 1 }
        }
    }
}

@Observable
final class FormModel {
    var name = ""
    var enabled = false
    var value = 1
    var changes: [String] = []
}

@MainActor
@Suite(.serialized)
struct ModifierAndControlTests {
    init() { Counter.reset() }

    @Test func customModifierHasOwnStateAndWrapsContent() {
        let host = TestHost(Text("content").modifier(Highlight()))
        #expect(host.texts == ["content", "highlight 0"])
        Counter.reset()
        host.tap("highlight 0")
        #expect(host.texts == ["content", "highlight 1"])
        #expect(Counter["Highlight"] == 1)
    }

    @Test func modifierAppliesToEachElementInListContext() {
        let host = TestHost(VStack {
            Group {
                Text("a")
                Text("b")
            }
            .padding(10)
        })
        let a = host.view(withText: "a")!.absoluteFrame
        let b = host.view(withText: "b")!.absoluteFrame
        // Each element gets its own padding: 10 + 8 (spacing) + 10 between the texts.
        #expect(b.minY - a.maxY == 28)
    }

    @Test func toggleAndTextFieldWriteThroughBindings() {
        struct Screen: View {
            @Bindable var model: FormModel
            var body: some View {
                VStack {
                    Toggle("Enabled", isOn: $model.enabled)
                    TextField("Name", text: $model.name)
                    Text(model.enabled ? "on \(model.name)" : "off \(model.name)")
                }
            }
        }
        let model = FormModel()
        let host = TestHost(Screen(model: model))
        host.setToggle(to: true)
        host.type("Ada")
        #expect(model.enabled)
        #expect(model.name == "Ada")
        #expect(host.texts.contains("on Ada"))
    }

    @Test func onChangeRunsAfterUpdateWithOldAndNewValues() {
        struct Screen: View {
            let model: FormModel
            var body: some View {
                Text("value \(model.value)")
                    .onChange(of: model.value) { old, new in model.changes.append("\(old)->\(new)") }
            }
        }
        let model = FormModel()
        let host = TestHost(Screen(model: model))
        #expect(model.changes.isEmpty)
        model.value = 2
        host.flush()
        model.value = 2
        host.flush()
        model.value = 5
        host.flush()
        #expect(model.changes == ["1->2", "2->5"])
    }

    @Test func environmentModifierReachesCompositeViewsInLists() {
        struct Reader: View {
            @Environment(\.lineLimit) var limit
            var body: some View { Text("limit \(limit ?? 0)") }
        }
        let host = TestHost(VStack {
            Reader()
            Reader()
        }.lineLimit(3))
        #expect(host.texts == ["limit 3", "limit 3"])
    }

    @Test func disabledPropagatesToButtons() {
        struct Screen: View {
            let model: FormModel
            var body: some View {
                Button("bump \(model.value)") { model.value += 1 }.disabled(true)
            }
        }
        let model = FormModel()
        let host = TestHost(Screen(model: model))
        host.tap("bump 1")
        #expect(model.value == 1)
    }

    @Test func tearDownRunsOnDisappear() {
        let host = TestHost(Text("x").onDisappear { Counter.hit("gone") })
        host.graph.tearDown()
        #expect(Counter["gone"] == 1)
        #expect(host.allViews.isEmpty)
    }
}

@MainActor
struct SceneTests {
    @Test func windowContentClosureIsTracked() {
        let model = FormModel()
        var windows: [WindowDescription] = []
        WindowGroup { Text("value \(model.value)") }._collectWindows(into: &windows)
        let backend = HeadlessBackend()
        let graph = windows[0].makeGraph(backend)
        graph.setProposedSize(ProposedViewSize(width: 200, height: 100))
        graph.update()
        model.value = 9
        graph.update()
        #expect(backend.root.allDescendants.compactMap(\.text) == ["value 9"])
    }
}
