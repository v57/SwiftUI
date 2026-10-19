import Foundation
import Testing
import UniformTypeIdentifiers
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
@Suite(.serialized)
struct PresentationFeatureTests {
    @Test func fileDialogOptionsReachTheRequest() {
        var requests: [FileDialogRequest] = []
        struct Screen: View {
            @State var importing = true
            var body: some View {
                Text("x")
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { _ in }
                    .fileDialogMessage("Pick a note")
                    .fileDialogConfirmationLabel("Use")
                    .fileDialogDefaultDirectory(URL(fileURLWithPath: "/tmp"))
                    .fileDialogBrowserOptions([.includeHiddenFiles])
            }
        }
        let host = TestHost(Screen().environment(\._fileDialogs, FileDialogPresenter { request, completion in
            requests.append(request)
            completion(nil)
        }))
        host.flush()
        #expect(requests.count == 1)
        let options = requests.first?.options
        #expect(options?.message == "Pick a note" && options?.confirmationLabel == "Use")
        #expect(options?.defaultDirectory?.path == "/tmp" && options?.showsHiddenFiles == true)
    }

    @Test func dialogIconSeverityAndSuppression() {
        struct Screen: View {
            @State var shown = true
            @State var suppressed = false
            var body: some View {
                Text("x")
                    .alert("Delete?", isPresented: $shown) { Button("OK") {} }
                    .dialogSeverity(.critical)
                    .dialogSuppressionToggle(isSuppressed: $suppressed)
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("Do not show this message again"))
        let images = host.allViews.compactMap { view -> String? in
            if case .image(let image) = view.content, case .system(let name) = image.source { return name } else { return nil }
        }
        #expect(images.contains("exclamationmark.triangle.fill"))
    }

    @Test func interactiveDismissCanBeBlockedOrConfirmed() {
        struct Screen: View {
            @State var blocked = true
            @State var confirmed = true
            var body: some View {
                VStack {
                    Text("base")
                }
                .sheet(isPresented: $blocked) { Text("locked").interactiveDismissDisabled() }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("locked"))
        host.pressEscape()
        host.finishAnimations()
        #expect(host.texts.contains("locked"))

        struct Confirming: View {
            @State var shown = true
            var body: some View {
                Text("base").sheet(isPresented: $shown) {
                    Text("editing").dismissalConfirmationDialog("Discard changes?", shouldPresent: true) {
                        Button("Discard", role: .destructive) { shown = false }
                    }
                }
            }
        }
        let confirming = TestHost(Confirming())
        confirming.flush()
        confirming.pressEscape()
        confirming.finishAnimations()
        #expect(confirming.texts.contains("Discard changes?"))
        #expect(confirming.texts.contains("editing"))
    }

    @Test func sheetBoundToAnObservableModelDismisses() {
        // The presenter's body doesn't read the flag (only makes a binding to it), so only observing it from the
        // presentation notices the dismissal.
        struct Screen: View {
            @State var window = PresentationWindowState()
            var body: some View {
                @Bindable var window = window
                Text("base").sheet(isPresented: $window.isWelcomeShown) { Text("welcome") }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("welcome"))
        host.pressEscape()
        host.finishAnimations()
        #expect(!host.texts.contains("welcome"))
    }

    @Test func sheetAppearanceFromContent() {
        struct Screen: View {
            @State var shown = true
            var body: some View {
                Text("base").sheet(isPresented: $shown) {
                    Text("sheet").presentationCornerRadius(20).presentationSizing(.form)
                }
            }
        }
        let host = TestHost(Screen(), size: CGSize(width: 900, height: 700))
        host.flush()
        let sheet = host.view(withText: "sheet")
        var container = sheet?.superview
        var widths: [CGFloat] = []
        while let view = container { widths.append(view.frame.width); container = view.superview }
        #expect(widths.contains { $0 >= 500 })
    }

    @Test func alertFromAnErrorBinding() {
        struct Failure: LocalizedError { var errorDescription: String? { "Upload failed" } }
        struct Screen: View {
            @State var error: Failure? = Failure()
            var body: some View {
                Text(error == nil ? "cleared" : "failing")
                    .alert(error: $error) { Button("Retry") {} }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("Upload failed") && host.texts.contains("Retry"))
        host.tap("Retry")
        host.finishAnimations()
        #expect(host.texts.contains("cleared") && !host.texts.contains("Upload failed"))
    }

    @Test func confirmationDialogPresentingDataAndItemAlerts() {
        struct Screen: View {
            @State var asking = true
            @State var item: String? = "notes.txt"
            var body: some View {
                VStack {
                    Text("a").confirmationDialog(Text("Remove"), isPresented: $asking, presenting: "draft.md") { name in
                        Button("Delete \(name)", role: .destructive) {}
                    } message: { name in Text("\(name) will be gone") }
                    Text("b").alert("Open", item: $item) { name in Button("Open \(name)") {} }
                }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("Delete draft.md") && host.texts.contains("draft.md will be gone") && host.texts.contains("Cancel"))
        #expect(host.texts.contains("Open notes.txt"))
    }
}

@Observable final class PresentationWindowState { var isWelcomeShown = true }
