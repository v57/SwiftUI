#if SWIFTUI2
import SwiftUI2
#else
import SwiftUI
#endif
import Foundation
import Observation

// MARK: - Models

@Observable
public final class PairModel {
    public var a = 0
    public var b = 0
    public init() {}
}

public final class PairObject: ObservableObject {
    @Published public var a = 0
    @Published public var b = 0
    public init() {}
}

@Observable
public final class ScreenModel {
    public var badge = "1"
    public var showBadge = true
    public var title = "Title"
    public var tint = Color.red
    public var items = [1, 2, 3, 4, 5]
    public var showDetail = true
    public var theme = "light"
    public var count = 0
    public init() {}
}

struct ThemeKey: EnvironmentKey { static let defaultValue = "light" }

extension EnvironmentValues {
    var parityTheme: String {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Views

struct ReadsA: View {
    let model: PairModel
    var body: some View {
        let _ = Probe.body("ReadsA")
        Text("a = \(model.a)")
    }
}

struct ReadsB: View {
    let model: PairModel
    var body: some View {
        let _ = Probe.body("ReadsB")
        Text("b = \(model.b)")
    }
}

struct ObservesA: View {
    @ObservedObject var object: PairObject
    var body: some View {
        let _ = Probe.body("ObservesA")
        Text("a = \(object.a)")
    }
}

struct ObservesB: View {
    @ObservedObject var object: PairObject
    var body: some View {
        let _ = Probe.body("ObservesB")
        Text("b = \(object.b)")
    }
}

struct HoldsObject: View {
    let object: PairObject
    var body: some View {
        let _ = Probe.body("HoldsObject")
        Text("holds")
    }
}

struct EnvObjectReader: View {
    @EnvironmentObject var object: PairObject
    var body: some View {
        let _ = Probe.body("EnvObjectReader")
        Text("env a = \(object.a)")
    }
}

struct StaticChild: View {
    let title: String
    var body: some View {
        let _ = Probe.body("StaticChild")
        Text(title)
    }
}

struct ValueChild: View {
    let value: Int
    var body: some View {
        let _ = Probe.body("ValueChild")
        Text("value \(value)")
    }
}

struct ParentReadsCount: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("ParentReadsCount")
        VStack {
            StaticChild(title: "static")
            ValueChild(value: model.count)
            ValueChild(value: 42)
        }
    }
}

struct Badge: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("Badge")
        Text(model.badge)
            .padding(4)
            .probeLayout("badge")
    }
}

struct OverlayScreen: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("OverlayScreen")
        VStack {
            Text("Header").probeLayout("header")
            Text("Card")
                .padding()
                .probeLayout("card")
                .overlay(alignment: .topTrailing) {
                    if model.showBadge { Badge(model: model) }
                }
            Text("Footer").probeLayout("footer")
        }
        .probeLayout("stack")
    }
}

struct BackgroundScreen: View {
    let model: ScreenModel
    var body: some View {
        VStack {
            Text("Header").probeLayout("header")
            Text("Card")
                .padding()
                .probeLayout("card")
                .background {
                    Text(model.badge).probeLayout("background")
                }
            Text("Footer").probeLayout("footer")
        }
        .probeLayout("stack")
    }
}

struct FixedFrameScreen: View {
    let model: ScreenModel
    var body: some View {
        VStack {
            Text("Header").probeLayout("header")
            Text(model.title).probeLayout("inner").frame(width: 160, height: 40)
            Text("Footer").probeLayout("footer")
        }
        .probeLayout("stack")
    }
}

struct TintScreen: View {
    let model: ScreenModel
    var body: some View {
        VStack {
            Text("Header").probeLayout("header")
            Text("Tinted").foregroundColor(model.tint).probeLayout("tinted")
        }
        .probeLayout("stack")
    }
}

struct ListRow: View {
    let item: Int
    var body: some View {
        let _ = Probe.body("ListRow")
        Text("row \(item)")
    }
}

struct ListScreen: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("ListScreen")
        VStack {
            ForEach(model.items, id: \.self) { ListRow(item: $0) }
        }
    }
}

struct Detail: View {
    var body: some View {
        let _ = Probe.body("Detail")
        Text("detail")
    }
}

struct ConditionalScreen: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("ConditionalScreen")
        VStack {
            if model.showDetail {
                Detail()
            } else {
                Text("placeholder")
            }
            StaticChild(title: "tail")
        }
    }
}

struct ThemeReader: View {
    @Environment(\.parityTheme) var theme
    var body: some View {
        let _ = Probe.body("ThemeReader")
        Text("theme \(theme)")
    }
}

struct LineLimitReader: View {
    @Environment(\.lineLimit) var lineLimit
    var body: some View {
        let _ = Probe.body("LineLimitReader")
        Text("limit \(lineLimit ?? -1)")
    }
}

struct ThemeScreen: View {
    let model: ScreenModel
    var body: some View {
        let _ = Probe.body("ThemeScreen")
        VStack {
            ThemeReader()
            LineLimitReader()
        }
        .environment(\.parityTheme, model.theme)
    }
}

@Observable
public final class LazyModel {
    public var values = Array(0..<500)
    public init() {}
}

struct LazyRowView: View {
    let value: Int
    var body: some View {
        let _ = Probe.body("LazyRowView")
        Text("row \(value)").frame(height: 30)
    }
}

struct LazyListScreen: View {
    let model: LazyModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.values.enumerated()), id: \.offset) { _, value in
                    LazyRowView(value: value)
                }
            }
        }
    }
}

// MARK: - Catalog

@MainActor
public enum ScenarioCatalog {
    public static func all() -> [ParityScenario] {
        [
            observableFineGrained(),
            observableObjectCoarse(),
            environmentObject(),
            unchangedChildInputs(),
            overlayIsolation(),
            backgroundIsolation(),
            fixedFrameBoundary(),
            colorChangeNoRelayout(),
            forEachEdits(),
            conditionalBranches(),
            environmentKeys(),
            lazyList(),
        ]
    }

    static func lazyList() -> ParityScenario {
        let model = LazyModel()
        return ParityScenario("lazy-list", root: LazyListScreen(model: model), steps: [
            ParityStep("change visible row") { model.values[3] = -3 },
            ParityStep("change offscreen row") { model.values[400] = -400 },
        ])
    }

    static func observableFineGrained() -> ParityScenario {
        let model = PairModel()
        return ParityScenario("observable-fine-grained", root: VStack {
            ReadsA(model: model)
            ReadsB(model: model)
        }, steps: [
            ParityStep("a += 1") { model.a += 1 },
            ParityStep("b += 1") { model.b += 1 },
        ])
    }

    static func observableObjectCoarse() -> ParityScenario {
        let object = PairObject()
        return ParityScenario("observable-object-coarse", root: VStack {
            ObservesA(object: object)
            ObservesB(object: object)
            HoldsObject(object: object)
        }, steps: [
            ParityStep("a += 1") { object.a += 1 },
            ParityStep("b = b") { object.b = object.b },
        ])
    }

    static func environmentObject() -> ParityScenario {
        let object = PairObject()
        return ParityScenario("environment-object", root: VStack {
            EnvObjectReader()
            StaticChild(title: "unrelated")
        }.environmentObject(object), steps: [
            ParityStep("a += 1") { object.a += 1 },
        ])
    }

    static func unchangedChildInputs() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("unchanged-child-inputs", root: ParentReadsCount(model: model), steps: [
            ParityStep("count += 1") { model.count += 1 },
        ])
    }

    static func overlayIsolation() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("overlay-isolation", root: OverlayScreen(model: model), steps: [
            ParityStep("grow badge") { model.badge = "12345" },
            ParityStep("hide badge") { model.showBadge = false },
            ParityStep("show badge") { model.showBadge = true },
        ])
    }

    static func backgroundIsolation() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("background-isolation", root: BackgroundScreen(model: model), steps: [
            ParityStep("grow background") { model.badge = "a much longer background" },
        ])
    }

    static func fixedFrameBoundary() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("fixed-frame-boundary", root: FixedFrameScreen(model: model), steps: [
            ParityStep("change title") { model.title = "Another title" },
        ])
    }

    static func colorChangeNoRelayout() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("color-change", root: TintScreen(model: model), steps: [
            ParityStep("tint blue") { model.tint = .blue },
        ])
    }

    static func forEachEdits() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("foreach-edits", root: ListScreen(model: model), steps: [
            ParityStep("insert front") { model.items.insert(0, at: 0) },
            ParityStep("remove middle") { model.items.removeAll { $0 == 3 } },
            ParityStep("reverse") { model.items.reverse() },
        ])
    }

    static func conditionalBranches() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("conditional-branches", root: ConditionalScreen(model: model), steps: [
            ParityStep("hide detail") { model.showDetail = false },
            ParityStep("show detail") { model.showDetail = true },
        ])
    }

    static func environmentKeys() -> ParityScenario {
        let model = ScreenModel()
        return ParityScenario("environment-keys", root: ThemeScreen(model: model), steps: [
            ParityStep("theme dark") { model.theme = "dark" },
        ])
    }
}
