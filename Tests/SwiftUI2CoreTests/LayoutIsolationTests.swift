import Foundation
import Observation
import Testing
import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class OverlayModel {
    var badge = "1"
    var showBadge = true
    var title = "Title"
    var color = Color.red
}

struct Badge: View {
    let model: OverlayModel
    var body: some View {
        let _ = Counter.hit("Badge")
        Text(model.badge).padding(4)
    }
}

struct OverlayScreen: View {
    let model: OverlayModel
    var body: some View {
        let _ = Counter.hit("OverlayScreen")
        VStack {
            Text("Header")
            Text("Card")
                .padding()
                .overlay(alignment: .topTrailing) {
                    if model.showBadge { Badge(model: model) }
                }
            HStack {
                Text("Footer")
                Spacer()
                Text("Right")
            }
        }
    }
}

struct BackgroundScreen: View {
    let model: OverlayModel
    var body: some View {
        VStack {
            Text("Header")
            Text("Card")
                .padding()
                .background {
                    Text(model.badge).font(.title)
                }
            Text("Footer")
        }
    }
}

/// The central guarantee: work caused by a change inside an overlay/background stays inside it.
@MainActor
@Suite(.serialized)
struct LayoutIsolationTests {
    init() { Counter.reset() }

    private func assertConfinedToSecondary(_ host: TestHost, marker: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let outside = host.tracer.events(UpdateTracer.layoutKinds.union([.renderInsert, .renderRemove, .renderContent]))
            .filter { !$0.path.contains(marker) }
        #expect(outside.isEmpty, "layout/render work leaked outside \(marker): \(outside)", sourceLocation: sourceLocation)
        for text in ["Header", "Card", "Footer"] {
            if let view = host.view(withText: text) {
                #expect(view.frameUpdates == 0, "\(text) was re-framed", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func overlayContentSizeChangeDoesNotLeak() throws {
        let model = OverlayModel()
        let host = TestHost(OverlayScreen(model: model))
        let before = try #require(host.view(withText: "1")).frame
        Counter.reset()
        host.resetTrace()

        model.badge = "12345"
        host.flush()

        let after = try #require(host.view(withText: "12345")).frame
        #expect(after.width > before.width)
        #expect(after.maxX == before.maxX) // still top-trailing aligned
        #expect(Counter["Badge"] == 1)
        #expect(Counter["OverlayScreen"] == 0)
        #expect(host.tracer.count(.sizeThatFits) > 0) // the overlay content did relayout...
        assertConfinedToSecondary(host, marker: "@overlay") // ...but nothing else did
    }

    @Test func overlayStructuralChangeDoesNotLeak() {
        let model = OverlayModel()
        let host = TestHost(OverlayScreen(model: model))
        host.resetTrace()
        model.showBadge = false
        host.flush()
        #expect(host.view(withText: "1") == nil)
        assertConfinedToSecondary(host, marker: "@overlay")

        host.resetTrace()
        model.showBadge = true
        host.flush()
        #expect(host.view(withText: "1") != nil)
        assertConfinedToSecondary(host, marker: "@overlay")
    }

    @Test func backgroundContentChangeDoesNotLeak() {
        let model = OverlayModel()
        let host = TestHost(BackgroundScreen(model: model))
        host.resetTrace()
        model.badge = "a much longer background label"
        host.flush()
        #expect(host.view(withText: "a much longer background label") != nil)
        assertConfinedToSecondary(host, marker: "@background")
    }

    @Test func primaryChangeRepositionsOverlay() throws {
        // The reverse dependency must still work: the overlay follows its primary view.
        struct Screen: View {
            let model: OverlayModel
            var body: some View {
                Text(model.title).overlay(alignment: .trailing) { Text("!") }
            }
        }
        let model = OverlayModel()
        let host = TestHost(Screen(model: model), size: CGSize(width: 400, height: 100))
        let before = try #require(host.view(withText: "!")).absoluteFrame
        model.title = "A much longer title"
        host.flush()
        let title = try #require(host.view(withText: "A much longer title")).absoluteFrame
        let after = try #require(host.view(withText: "!")).absoluteFrame
        #expect(after.maxX == title.maxX)
        #expect(after.maxX != before.maxX)
    }

    @Test func fixedFrameIsALayoutBoundary() {
        struct Screen: View {
            let model: OverlayModel
            var body: some View {
                VStack {
                    Text("Header")
                    Text(model.badge).frame(width: 120, height: 40)
                    Text("Footer")
                }
            }
        }
        let model = OverlayModel()
        let host = TestHost(Screen(model: model))
        host.resetTrace()
        model.badge = "changed text"
        host.flush()
        #expect(host.tracer.count(.placement) { $0.hasSuffix("VStack") } == 0)
        #expect(host.tracer.count(.sizeThatFits) { $0.hasSuffix("VStack") } == 0)
        #expect(host.view(withText: "Header")!.frameUpdates == 0)
        #expect(host.view(withText: "Footer")!.frameUpdates == 0)
    }

    @Test func colorChangeNeverRelayouts() {
        struct Screen: View {
            let model: OverlayModel
            var body: some View {
                VStack {
                    Text("Header")
                    Text("Tinted").foregroundColor(model.color)
                }
            }
        }
        let model = OverlayModel()
        let host = TestHost(Screen(model: model))
        host.resetTrace()
        model.color = .blue
        host.flush()
        #expect(host.tracer.count(.sizeThatFits) == 0)
        #expect(host.tracer.count(.placement) == 0)
        #expect(host.tracer.count(.renderFrame) == 0)
        #expect(host.tracer.count(.renderContent) == 1)
    }

    @Test func siblingTextChangeOnlyReframesAffectedViews() {
        struct Screen: View {
            let model: OverlayModel
            var body: some View {
                VStack(alignment: .leading) {
                    Text("Header")
                    Text(model.title)
                    Text("Footer")
                }
            }
        }
        let model = OverlayModel()
        let host = TestHost(Screen(model: model), size: CGSize(width: 400, height: 400))
        host.resetTrace()
        model.title = "Title, but longer"
        host.flush()
        // Leading-aligned stack: the stack grows, so all rows move horizontally when re-centered,
        // but no view is re-rendered except the changed text.
        #expect(host.tracer.count(.renderContent) == 1)
    }
}
