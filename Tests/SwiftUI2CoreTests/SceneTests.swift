import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SwiftUI2Core
import SwiftUI2Headless

struct NoteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct NoteEditor: View {
    @Binding var document: NoteDocument
    var body: some View {
        VStack {
            Text("text: \(document.text)")
            Button("type") { document.text += "!" }
        }
    }
}

@MainActor
@Suite(.serialized)
struct SceneFeatureTests {
    @Test func sceneModifiersDescribeWindows() {
        let scene = WindowGroup("Main") { Text("x") }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultPosition(.topLeading)
            .windowToolbarStyle(.unifiedCompact)
            .defaultSize(width: 400, height: 300)
        var windows: [WindowDescription] = []
        scene._collectWindows(into: &windows)
        #expect(windows.count == 1)
        let window = windows[0]
        #expect(window.kind == .hiddenTitleBar)
        #expect(window.resizability == .contentSize)
        #expect(window.defaultPosition == .topLeading)
        #expect(window.toolbarStyle == .unifiedCompact)
        #expect(window.defaultSize == CGSize(width: 400, height: 300))
    }

    @Test func utilityWindowsAndMenuBarExtras() {
        var windows: [WindowDescription] = []
        UtilityWindow("Inspector", id: "inspector") { Text("i") }._collectWindows(into: &windows)
        MenuBarExtra("Status", systemImage: "star") { Button("Quit") {} }._collectWindows(into: &windows)
        #expect(windows[0].kind == .utility && windows[0].level == .floating && windows[0].id == "inspector")
        #expect(!windows[0].opensAtLaunch)
        let extra = windows[1].menuBarExtra
        #expect(extra?.title == "Status" && extra?.systemImage == "star")
        if case .button(let title, _, _, _, _, _)? = extra?.menuItems().first { #expect(title == "Quit") } else { Issue.record("no menu item") }
        #expect(!windows[1].opensAtLaunch)
    }

    @Test func documentGroupCreatesEditsSavesAndOpens() throws {
        var windows: [WindowDescription] = []
        DocumentGroup(newDocument: NoteDocument(text: "hi")) { configuration in
            NoteEditor(document: configuration.$document)
        }._collectWindows(into: &windows)
        let scene = try #require(windows.first)
        let documents = try #require(scene.document)
        #expect(documents.readableTypeIdentifiers == [UTType.plainText.identifier])
        // A new document renders through the editor and marks edits.
        let handle = try #require(documents.makeNew?())
        let window = TestHostWindow(scene: scene, handle: handle)
        #expect(window.host.texts.contains("text: hi"))
        window.host.tap("type")
        #expect(window.host.texts.contains("text: hi!"))
        #expect(handle.isEdited)
        // Save, then open the file again.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try handle.write(to: url, typeIdentifier: UTType.plainText.identifier)
        #expect(!handle.isEdited && handle.fileURL == url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hi!")
        let reopened = try documents.open(url)
        let second = TestHostWindow(scene: scene, handle: reopened)
        #expect(second.host.texts.contains("text: hi!"))
    }

    @Test func systemButtonsUseRuntimeHooks() {
        var log: [String] = []
        AppRuntime.openSettings = { log.append("settings") }
        AppRuntime.isWindowOpen = { _ in false }
        AppRuntime.openWindow = { id, _ in log.append("open \(id ?? "-")") }
        defer {
            AppRuntime.openSettings = nil
            AppRuntime.isWindowOpen = nil
            AppRuntime.openWindow = nil
        }
        let host = TestHost(VStack {
            SettingsLink { Text("Prefs") }
            WindowVisibilityToggle(windowID: "inspector") { Text("Inspector") }
            RenameButton().renameAction { log.append("rename") }
            PasteButton(supportedContentTypes: [.plainText]) { providers in log.append("paste \(providers.count)") }
        }.environment(\._pasteboardReader, PasteboardReader { [NSItemProvider(object: "x" as NSString)] }))
        host.tap("Prefs")
        host.tap("Inspector")
        host.tap("Rename")
        host.tap("Paste")
        #expect(log == ["settings", "open inspector", "rename", "paste 1"])
    }
}

/// A headless window for a document scene's graph.
@MainActor
struct TestHostWindow {
    let host: TestHost
    init(scene: WindowDescription, handle: any _DocumentHandle) {
        host = TestHost(graph: { backend in scene.makeGraphForValue(backend, AnyHashable(_DocumentWindowValue(handle: handle))) })
    }
}

@MainActor
@Suite(.serialized)
struct WindowConfigurationTests {
    @Test func innerViewsOverrideWindowBehavior() {
        let host = TestHost(VStack {
            Text("a").windowResizeBehavior(.enabled)
            Text("b").toolbar(.hidden, for: .windowToolbar)
        }.windowResizeBehavior(.disabled).windowFullScreenBehavior(.disabled))
        host.flush()
        let configuration = host.graph.windowConfiguration
        #expect(configuration.resizeBehavior == .enabled)
        #expect(configuration.fullScreenBehavior == .disabled)
        #expect(configuration.isToolbarHidden == true)
    }
}
