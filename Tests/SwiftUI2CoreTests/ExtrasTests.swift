import Foundation
import Combine
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@MainActor
@Suite(.serialized)
struct ExtrasTests {
    init() { Counter.reset() }

    @Test func canvasRecordsDrawing() {
        let host = TestHost(Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red))
            context.stroke(Path(ellipseIn: CGRect(x: 0, y: 0, width: 10, height: 10)), with: .color(.blue), lineWidth: 2)
        }.frame(width: 50, height: 50))
        let canvas = host.allViews.first { if case .drawing = $0.content { return true }; return false }
        guard case .drawing(let commands)? = canvas?.content else { Issue.record("no canvas"); return }
        #expect(commands.count == 2)
    }

    @Test func tableRendersHeadersAndRows() {
        struct Person: Identifiable { let id: Int; let name: String; let age: Int }
        let people = [Person(id: 1, name: "Ada", age: 36), Person(id: 2, name: "Alan", age: 41)]
        let host = TestHost(Table(people) {
            TableColumn("Name", value: \.name)
            TableColumn("Age") { Text("\($0.age)") }
        })
        for text in ["Name", "Age", "Ada", "Alan", "36", "41"] { #expect(host.texts.contains(text)) }
        let ada = host.view(withText: "Ada")!.absoluteFrame
        let age = host.view(withText: "36")!.absoluteFrame
        #expect(abs(ada.midY - age.midY) < 1) // same row
        #expect(age.minX > ada.maxX) // later column
    }

    @Test func safeAreaInsetStacksBar() {
        let host = TestHost(Color.red.safeAreaInset(edge: .bottom) { Text("Bar") }, size: CGSize(width: 200, height: 200))
        let bar = host.view(withText: "Bar")!.absoluteFrame
        #expect(bar.maxY == 200)
    }

    @Test func onReceiveDeliversPublisherValues() {
        let subject = PassthroughSubject<Int, Never>()
        struct Screen: View {
            let subject: PassthroughSubject<Int, Never>
            @State var last = 0
            var body: some View {
                Text("last \(last)").onReceive(subject) { last = $0 }
            }
        }
        let host = TestHost(Screen(subject: subject))
        subject.send(42)
        host.flush()
        #expect(host.texts == ["last 42"])
    }

    @Test func equatableSkipsBodyWhenEqual() {
        struct Leaf: View, Equatable {
            let value: Int
            let ignored: () -> Void
            nonisolated static func == (lhs: Leaf, rhs: Leaf) -> Bool { lhs.value == rhs.value }
            var body: some View {
                let _ = Counter.hit("EquatableLeaf")
                Text("v \(value)")
            }
        }
        struct Parent: View {
            @State var tick = 0
            var body: some View {
                VStack {
                    Button("tick \(tick)") { tick += 1 }
                    Leaf(value: 1, ignored: { _ = tick }).equatable()
                }
            }
        }
        let host = TestHost(Parent())
        Counter.reset()
        host.tap("tick 0")
        #expect(Counter["EquatableLeaf"] == 0) // closure changed, but == says equal
    }

    @Test func appStoragePersistsAndObserves() {
        let suite = "SwiftUI2Tests.\\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        struct Screen: View {
            @AppStorage("count", store: UserDefaults(suiteName: ExtrasSuite.name)) var count = 0
            var body: some View { Button("count \(count)") { count += 1 } }
        }
        ExtrasSuite.name = suite
        let host = TestHost(Screen())
        host.tap("count 0")
        #expect(host.texts == ["count 1"])
        #expect(defaults.integer(forKey: "count") == 1)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func outlineGroupAndControlGroup() {
        struct Node: Identifiable { let id: String; var children: [Node]? }
        let tree = [Node(id: "root", children: [Node(id: "leaf", children: nil)])]
        let host = TestHost(VStack {
            OutlineGroup(tree, children: \.children) { Text($0.id) }
            ControlGroup {
                Button("A") {}
                Button("B") {}
            }
        })
        #expect(host.texts.contains("root"))
        #expect(!host.texts.contains("leaf")) // collapsed
        host.tap("root")
        host.finishAnimations()
        #expect(host.texts.contains("leaf"))
        #expect(host.texts.contains("A") && host.texts.contains("B"))
    }
}

@MainActor
enum ExtrasSuite {
    static var name = ""
}
