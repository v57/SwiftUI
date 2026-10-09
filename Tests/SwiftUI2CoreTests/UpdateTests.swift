import Foundation
import Observation
import Testing
import SwiftUI2Core
import SwiftUI2Headless

// MARK: - Fixtures

@Observable
final class TwoFieldModel {
    var a = 0
    var b = 0
}

final class LegacySettings: ObservableObject {
    @Published var a = 0
    @Published var b = 0
}

struct StaticLeaf: View {
    let title: String
    var body: some View {
        let _ = Counter.hit("StaticLeaf")
        Text(title)
    }
}

struct CounterView: View {
    @State private var count = 0
    var body: some View {
        let _ = Counter.hit("CounterView")
        VStack {
            Text("count \(count)")
            Button("inc") { count += 1 }
            StaticLeaf(title: "fixed")
        }
    }
}

struct WriteOnlyStateView: View {
    @State private var hidden = 0
    var body: some View {
        let _ = Counter.hit("WriteOnlyStateView")
        Button("poke") { hidden += 1 }
    }
}

struct ReadsA: View {
    let model: TwoFieldModel
    var body: some View {
        let _ = Counter.hit("ReadsA")
        Text("a=\(model.a)")
    }
}

struct ReadsB: View {
    let model: TwoFieldModel
    var body: some View {
        let _ = Counter.hit("ReadsB")
        Text("b=\(model.b)")
    }
}

struct ObservesA: View {
    @ObservedObject var settings: LegacySettings
    var body: some View {
        let _ = Counter.hit("ObservesA")
        Text("a=\(settings.a)")
    }
}

struct ObservesB: View {
    @ObservedObject var settings: LegacySettings
    var body: some View {
        let _ = Counter.hit("ObservesB")
        Text("b=\(settings.b)")
    }
}

struct HoldsSettingsWithoutObserving: View {
    let settings: LegacySettings
    var body: some View {
        let _ = Counter.hit("HoldsSettingsWithoutObserving")
        Text("plain")
    }
}

struct EnvironmentSettingsReader: View {
    @EnvironmentObject var settings: LegacySettings
    var body: some View {
        let _ = Counter.hit("EnvironmentSettingsReader")
        Text("env a=\(settings.a)")
    }
}

struct ThemeKey: EnvironmentKey { static let defaultValue = "light" }
extension EnvironmentValues {
    var theme: String {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemeReader: View {
    @Environment(\.theme) var theme
    var body: some View {
        let _ = Counter.hit("ThemeReader")
        Text("theme \(theme)")
    }
}

struct LineLimitReader: View {
    @Environment(\.lineLimit) var lineLimit
    var body: some View {
        let _ = Counter.hit("LineLimitReader")
        Text("limit \(lineLimit ?? 0)")
    }
}

@Observable
final class ThemeModel {
    var theme = "light"
}

struct ThemedRoot: View {
    let model: ThemeModel
    var body: some View {
        let _ = Counter.hit("ThemedRoot")
        VStack {
            ThemeReader()
            LineLimitReader()
        }
        .environment(\.theme, model.theme)
    }
}

// MARK: - Tests

@MainActor
@Suite(.serialized)
struct UpdateTests {
    init() { Counter.reset() }

    @Test func initialRenderEvaluatesEachBodyOnce() {
        _ = TestHost(CounterView())
        #expect(Counter["CounterView"] == 1)
        #expect(Counter["StaticLeaf"] == 1)
    }

    @Test func stateChangeOnlyUpdatesOwnerNotUnchangedChildren() {
        let host = TestHost(CounterView())
        Counter.reset()
        host.tap("inc")
        #expect(host.texts.contains("count 1"))
        #expect(Counter["CounterView"] == 1)
        #expect(Counter["StaticLeaf"] == 0) // inputs unchanged → body skipped
    }

    @Test func settingStateThatBodyDoesNotReadDoesNotUpdate() {
        let host = TestHost(WriteOnlyStateView())
        Counter.reset()
        host.tap("poke")
        #expect(Counter["WriteOnlyStateView"] == 0)
    }

    @Test func observableTracksIndividualProperties() {
        let model = TwoFieldModel()
        let host = TestHost(VStack {
            ReadsA(model: model)
            ReadsB(model: model)
        })
        Counter.reset()
        model.a = 1
        host.flush()
        #expect(host.texts.contains("a=1"))
        #expect(Counter["ReadsA"] == 1)
        #expect(Counter["ReadsB"] == 0)

        model.a = 1 // same value: Observation still fires willSet; body re-runs, render is cut off
        host.flush()
        host.resetTrace()
        model.b = 5
        host.flush()
        #expect(Counter["ReadsB"] == 1)
        #expect(host.tracer.count(.renderContent) == 1)
    }

    @Test func observableObjectInvalidatesEveryObserver() {
        let settings = LegacySettings()
        let host = TestHost(VStack {
            ObservesA(settings: settings)
            ObservesB(settings: settings)
            HoldsSettingsWithoutObserving(settings: settings)
        })
        Counter.reset()
        settings.a = 1
        host.flush()
        #expect(host.texts.contains("a=1"))
        #expect(Counter["ObservesA"] == 1)
        #expect(Counter["ObservesB"] == 1) // ObservableObject: whole-object invalidation
        #expect(Counter["HoldsSettingsWithoutObserving"] == 0)
    }

    @Test func environmentObjectUpdatesReaders() {
        let settings = LegacySettings()
        let host = TestHost(VStack {
            EnvironmentSettingsReader()
            StaticLeaf(title: "other")
        }.environmentObject(settings))
        Counter.reset()
        settings.a = 7
        host.flush()
        #expect(host.texts.contains("env a=7"))
        #expect(Counter["EnvironmentSettingsReader"] == 1)
        #expect(Counter["StaticLeaf"] == 0)
    }

    @Test func environmentReadersUpdateOnlyForTheirKey() {
        let model = ThemeModel()
        let host = TestHost(ThemedRoot(model: model))
        Counter.reset()
        model.theme = "dark"
        host.flush()
        #expect(host.texts.contains("theme dark"))
        #expect(Counter["ThemedRoot"] == 1)
        #expect(Counter["ThemeReader"] == 1)
        #expect(Counter["LineLimitReader"] == 0)
    }

    @Test func bindingPropagatesToParent() {
        struct Child: View {
            @Binding var value: Int
            var body: some View {
                let _ = Counter.hit("BindingChild")
                Button("bump \(value)") { value += 1 }
            }
        }
        struct Parent: View {
            @State var value = 0
            var body: some View {
                let _ = Counter.hit("BindingParent")
                VStack {
                    Text("parent \(value)")
                    Child(value: $value)
                }
            }
        }
        let host = TestHost(Parent())
        Counter.reset()
        host.tap("bump 0")
        #expect(host.texts.contains("parent 1"))
        #expect(host.texts.contains("bump 1"))
        #expect(Counter["BindingParent"] == 1)
        #expect(Counter["BindingChild"] == 1)
    }
}

// MARK: - Identity

@Observable
final class ListModel {
    var items: [Int] = [1, 2, 3]
    var show = true
    var useText = true
    var identity = 0
}

struct Row: View {
    let item: Int
    @State private var taps = 0
    var body: some View {
        let _ = Counter.hit("Row")
        Button("row \(item) taps \(taps)") { taps += 1 }
    }
}

struct Lifecycle: View {
    @State private var taps = 0
    var body: some View {
        Button("lifecycle \(taps)") { taps += 1 }
            .onAppear { Counter.hit("appear") }
            .onDisappear { Counter.hit("disappear") }
    }
}

@MainActor
@Suite(.serialized)
struct IdentityTests {
    init() { Counter.reset() }

    @Test func forEachInsertionKeepsStateAndOnlyBuildsNewRow() {
        let model = ListModel()
        struct Rows: View {
            let model: ListModel
            var body: some View {
                VStack {
                    ForEach(model.items, id: \.self) { Row(item: $0) }
                }
            }
        }
        let host = TestHost(Rows(model: model))
        host.tap("row 2 taps 0")
        Counter.reset()
        model.items.insert(0, at: 0)
        host.flush()
        #expect(host.texts == ["row 0 taps 0", "row 1 taps 0", "row 2 taps 1", "row 3 taps 0"])
        #expect(Counter["Row"] == 1)
        Counter.reset()
        model.items.removeAll { $0 == 1 }
        host.flush()
        #expect(host.texts == ["row 0 taps 0", "row 2 taps 1", "row 3 taps 0"])
        #expect(Counter["Row"] == 0)
        model.items.reverse()
        host.flush()
        #expect(host.texts == ["row 3 taps 0", "row 2 taps 1", "row 0 taps 0"])
    }

    @Test func conditionalResetsStateAndFiresLifecycle() {
        let model = ListModel()
        struct Screen: View {
            let model: ListModel
            var body: some View {
                VStack {
                    if model.show { Lifecycle() }
                    Text("tail")
                }
            }
        }
        let host = TestHost(Screen(model: model))
        #expect(Counter["appear"] == 1)
        host.tap("lifecycle 0")
        #expect(host.texts.first == "lifecycle 1")
        model.show = false
        host.flush()
        #expect(host.texts == ["tail"])
        #expect(Counter["disappear"] == 1)
        model.show = true
        host.flush()
        #expect(host.texts == ["lifecycle 0", "tail"]) // new identity → fresh state
        #expect(Counter["appear"] == 2)
    }

    @Test func explicitIdentityResetsState() {
        let model = ListModel()
        struct Screen: View {
            let model: ListModel
            var body: some View { Lifecycle().id(model.identity) }
        }
        let host = TestHost(Screen(model: model))
        host.tap("lifecycle 0")
        #expect(host.texts == ["lifecycle 1"])
        model.identity = 1
        host.flush()
        #expect(host.texts == ["lifecycle 0"])
        #expect(Counter["disappear"] == 1)
    }

    @Test func anyViewTypeChangeReplacesSubtree() {
        let model = ListModel()
        struct Switcher: View {
            let model: ListModel
            var body: some View {
                model.useText ? AnyView(Text("text")) : AnyView(Color.red)
            }
        }
        let host = TestHost(Switcher(model: model))
        #expect(host.texts == ["text"])
        model.useText = false
        host.flush()
        #expect(host.texts.isEmpty)
        #expect(host.allViews.count == 1)
    }
}
