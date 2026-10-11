import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

struct SelectedNoteKey: FocusedValueKey { typealias Value = String }
struct SceneTitleKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var selectedNote: String? {
        get { self[SelectedNoteKey.self] }
        set { self[SelectedNoteKey.self] = newValue }
    }
    var sceneTitle: String? {
        get { self[SceneTitleKey.self] }
        set { self[SceneTitleKey.self] = newValue }
    }
}

struct FocusedReader: View {
    @FocusedValue(\.selectedNote) var note
    @FocusedValue(\.sceneTitle) var title
    var body: some View { Text("note \(note ?? "-") title \(title ?? "-")") }
}

@MainActor
@Suite(.serialized)
struct FocusCommandTests {
    @Test func focusedValuesFollowFocus() throws {
        let host = TestHost(VStack {
            FocusedReader()
            Text("editor").focusable().focusedValue(\.selectedNote, "A")
            Text("other").focusable()
        }.focusedSceneValue(\.sceneTitle, "Doc"))
        FocusedValuesCenter.shared.activate(host.graph)
        host.flush()
        #expect(host.texts.first == "note - title Doc")
        // Focus the editor: its focused value becomes visible.
        let editor = try #require(host.allViews.first { view in
            if case .effect(.focusable) = view.content { return view.children.contains { $0.text == "editor" } }
            return false
        })
        host.graph.setFocusedNode(editor.node)
        host.flush()
        #expect(host.texts.first == "note A title Doc")
        let other = try #require(host.allViews.first { view in
            if case .effect(.focusable) = view.content { return view.children.contains { $0.text == "other" } }
            return false
        })
        host.graph.setFocusedNode(other.node)
        host.flush()
        #expect(host.texts.first == "note - title Doc")
    }

    #if canImport(ObjectiveC) && canImport(CoreTransferable)
    @Test func commandsReachTheirHandlers() {
        let log = ScrollLog()
        var written: [Any] = []
        let host = TestHost(VStack {
            Text("doc")
                .copyable(["copied text"])
                .onCommand(Selector(("archive:"))) { log.events.append("archive") }
        }.environment(\._pasteboard, PasteboardWriter { written = $0 }))
        #expect(host.graph.canHandleCommand("copy:"))
        #expect(host.graph.canHandleCommand("archive:"))
        #expect(!host.graph.canHandleCommand("cut:"))
        host.graph.handleCommand("copy:")
        host.graph.handleCommand("archive:")
        #expect(written as? [String] == ["copied text"])
        #expect(log.events == ["archive"])
    }
    #endif

    @Test func modifierKeysAndHaptics() {
        let log = ScrollLog()
        var played: [SensoryFeedback] = []
        struct Screen: View {
            let log: ScrollLog
            @State var count = 0
            var body: some View {
                Button("bump \(count)") { count += 1 }
                    .onModifierKeysChanged(mask: .option, initial: false) { _, new in log.events.append(new.contains(.option) ? "option down" : "option up") }
                    .sensoryFeedback(.increase, trigger: count)
            }
        }
        let host = TestHost(Screen(log: log).environment(\._haptics, HapticPerformer { played.append($0) }))
        host.graph.handleModifierFlags([.option, .shift])
        host.graph.handleModifierFlags([.shift])
        #expect(log.events == ["option down", "option up"])
        host.tap("bump 0")
        #expect(played == [.increase])
    }

    @Test func pointerAndFocusEffectsReachRenderTree() {
        let host = TestHost(VStack {
            Text("link").pointerStyle(.link)
            Text("field").focusable().focusEffectDisabled()
        })
        let effects = host.allViews.compactMap { view -> DisplayEffect? in
            if case .effect(let effect) = view.content { return effect } else { return nil }
        }
        #expect(effects.contains(.pointer(.link, hidden: false)))
        #expect(effects.contains(.focusable(wantsFocus: false, showsFocusRing: false)))
    }
}
