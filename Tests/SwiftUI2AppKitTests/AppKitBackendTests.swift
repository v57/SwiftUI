#if canImport(AppKit)
import AppKit
import Testing
@testable import SwiftUI2AppKit
import SwiftUI2

@MainActor
struct AppKitBackendTests {
    struct CounterView: View {
        @State var count = 0
        var body: some View {
            VStack {
                Text("count \(count)")
                Button("increment") { count += 1 }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func click(_ view: NSView, in window: NSWindow) {
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    @Test func buildsNativeViewsAndHandlesClicks() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: CounterView())
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)

        let views = descendants(of: host)
        let texts = views.compactMap { $0 as? TextNodeView }
        let button = try #require(views.first { $0 is ButtonNodeView })
        #expect(texts.count == 2)
        #expect(button.frame.height == 20)  // SwiftUI bordered buttons are 20pt tall on macOS
        #expect(button.subviews.first is TextNodeView) // label is a child of the bezel view

        click(button, in: window)
        host.graph.update() // what the run-loop observer does
        let counter = try #require(host.graph.tracer.events.last { $0.kind == .renderContent })
        #expect(counter.path.hasSuffix("Text"))
        #expect(host.graph.renderer.root.platformChildren.contains { node in
            if case .text(let text) = node.content { return text.string == "count 1" }
            return false
        })
    }

    @Test func accessibilityReachesNativeViews() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        var pressed = 0
        let host = NSHostingView(rootView: VStack {
            Text("5").accessibilityLabel("Count").accessibilityHint("Number of items")
            Color.red.frame(width: 20, height: 20).accessibilityAddTraits(.isButton).accessibilityAction { pressed += 1 }
        })
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.graph.update()
        let views = descendants(of: host)
        let text = try #require(views.first { $0 is TextNodeView })
        #expect(text.accessibilityLabel() == "Count")
        #expect(text.accessibilityHelp() == "Number of items")
        #expect(text.accessibilityValue() as? String == "5")
        let button = try #require(views.first { $0.accessibilityRole() == .button })
        #expect(button.accessibilityPerformPress())
        #expect(pressed == 1)
    }

    @Test func responderChainCommandsUseTrampolines() throws {
        var archived = 0
        let host = NSHostingView(rootView: Text("doc").onCommand(Selector(("archiveDocument:"))) { archived += 1 })
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        host.graph.update()
        let selector = Selector(("archiveDocument:"))
        let target = try #require(host.supplementalTarget(forAction: selector, sender: nil) as? NSObject)
        #expect(target.responds(to: selector))
        _ = target.perform(selector, with: nil)
        #expect(archived == 1)
        #expect(host.supplementalTarget(forAction: Selector(("unknownAction:")), sender: nil) == nil)
    }

    @Test func windowConfigurationAppliesToNativeWindows() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: Text("x")
            .windowResizeBehavior(.disabled)
            .windowMinimizeBehavior(.disabled)
            .navigationDocument(URL(fileURLWithPath: "/tmp/doc.txt"))
            .containerBackground(Color.red, for: .window)
            .allowsWindowActivationEvents())
        window.contentView = host
        host.graph.update()
        AppKitAppRunner.apply(host.graph.windowConfiguration, to: window, host: host, sceneResizable: true)
        #expect(!window.styleMask.contains(.resizable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.closable))
        #expect(window.representedURL?.path == "/tmp/doc.txt")
        #expect(host.acceptsFirstMouse(for: nil))
        let red = try #require(window.backgroundColor.usingColorSpace(.sRGB))
        #expect(red.redComponent > 0.9 && red.greenComponent < 0.3)
    }

    @Test func textMeasurementMatchesDrawing() {
        let backend = AppKitBackend(rootView: NSView())
        let text = Text("Hello, world").resolve(in: EnvironmentValues())
        let single = backend.measureText(text, proposal: .unspecified)
        let wrapped = backend.measureText(text, proposal: ProposedViewSize(width: single.width / 2, height: nil))
        #expect(single.height > 0)
        #expect(wrapped.height > single.height)
        #expect(wrapped.width <= single.width / 2)
        // Stacks probe flexibility with an infinite proposal: it must measure like an ideal size.
        #expect(backend.measureText(text, proposal: ProposedViewSize(width: .infinity, height: nil)) == single)
    }

    /// Frames of probed views (window coordinates) after a layout pass.
    private func frames<V: View>(of view: V, size: CGSize = CGSize(width: 600, height: 400)) -> [String: CGRect] {
        let box = FramesBox()
        let host = NSHostingView(rootView: view.coordinateSpace(name: "root").onPreferenceChange(ProbeKey.self) { box.frames = $0 })
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.graph.update()
        return box.frames
    }

    /// Spacing measured on macOS SwiftUI (see docs): text/text 0 (default font), text style leading,
    /// font-dependent gaps between text and other views, 20pt bordered buttons.
    @Test func textSpacingMatchesSwiftUI() {
        let frames = frames(of: VStack {
            Text("Hg").probeFrame("t1")
            Text("Hg").probeFrame("t2")
            Color.red.frame(width: 10, height: 10).probeFrame("c1")
            Text("Hg").probeFrame("t3")
            Text("Hg").font(.body).probeFrame("t4")
            Button("B") {}.probeFrame("b1")
        })
        func gap(_ a: String, _ b: String) -> CGFloat { frames[b]!.minY - frames[a]!.maxY }
        #expect(frames["t1"]!.height == 16)
        #expect(gap("t1", "t2") == 0)
        #expect(abs(gap("t2", "c1") - 8.15) < 0.01)
        #expect(abs(gap("c1", "t3") - 4.74) < 0.01)
        #expect(gap("t3", "t4") == 1)
        #expect(abs(gap("t4", "b1") - 8.15) < 0.01)
        #expect(frames["b1"]!.height == 20)
    }
}

private final class FramesBox { var frames: [String: CGRect] = [:] }

private struct ProbeKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private extension View {
    func probeFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ProbeKey.self, value: [name: proxy.frame(in: .named("root"))])
        })
    }
}
#endif
