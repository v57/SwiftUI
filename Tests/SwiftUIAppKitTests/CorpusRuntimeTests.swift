#if canImport(AppKit)
import AppKit
import Testing
@testable import SwiftUIAppKit
import SwiftUI

/// Hosts every corpus view in a window: building, laying out and updating must not crash.
@MainActor
@Suite(.serialized)
struct CorpusRuntimeTests {
    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 800, height: 600)) -> Int {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.graph.update()
        hosting.frame = CGRect(origin: .zero, size: CGSize(width: size.width / 2, height: size.height / 2))
        hosting.layoutSubtreeIfNeeded()
        hosting.graph.update()
        func count(_ view: NSView) -> Int { 1 + view.subviews.map(count).reduce(0, +) }
        return count(hosting)
    }

    @Test func shapesAndLayout() {
        #expect(host(CorpusShapes()) > 10)
        #expect(host(CorpusLayout()) > 10)
    }

    @Test func controlsAndLists() {
        #expect(host(CorpusControls(model: CorpusModel())) > 10)
        #expect(host(CorpusLists()) > 5)
    }

    @Test func navigationAnimationAndDragDrop() {
        #expect(host(CorpusNavigation()) > 5)
        #expect(host(CorpusAnimation()) > 5)
        #expect(host(CorpusDragDrop()) > 3)
        #expect(host(CorpusToolbarAndCommands()) > 1)
    }

    @Test func textImagesAndData() {
        #expect(host(CorpusText()) > 10)
        #expect(host(CorpusImages()) > 3)
        let legacy = LegacyModel()
        #expect(host(CorpusDataFlow(observed: legacy).environmentObject(legacy)) > 1)
        #expect(host(CorpusLegacyTabs()) > 1)
        #expect(host(CorpusScrollGeometry()) > 3)
        #expect(host(CorpusColorsAndMisc()) > 10)
    }

    @Test func extensionPoints() {
        #expect(host(CorpusExtensionPoints()) > 10)
    }
}
#endif
