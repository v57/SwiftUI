import Foundation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

struct LazyRow: View {
    let index: Int
    var body: some View {
        let _ = Counter.hit("LazyRow")
        Text("row \(index)").frame(height: 20)
    }
}

@MainActor
@Suite(.serialized)
struct LazyTests {
    init() { Counter.reset() }

    @Test func lazyVStackBuildsOnlyVisibleRows() {
        let host = TestHost(ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<1000, id: \.self) { LazyRow(index: $0) }
            }
        }, size: CGSize(width: 300, height: 200))
        // 200pt viewport of 20pt rows (+ overscan) → a few dozen rows, not 1000.
        #expect(Counter["LazyRow"] > 5)
        #expect(Counter["LazyRow"] < 40)
        #expect(host.texts.contains("row 0"))
        #expect(!host.texts.contains("row 500"))

        Counter.reset()
        host.scroll(to: CGPoint(x: 0, y: 10_000))
        #expect(host.texts.contains("row 500"))
        #expect(!host.texts.contains("row 0"))
        #expect(Counter["LazyRow"] < 40)
        // Rows are placed at their real offsets in the scroll content.
        let row = host.view(withText: "row 500")!
        #expect(row.frame.midY == 10_010)
    }

    @Test func eagerVStackBuildsEverything() {
        _ = TestHost(ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<200, id: \.self) { LazyRow(index: $0) }
            }
        }, size: CGSize(width: 300, height: 200))
        #expect(Counter["LazyRow"] == 200)
    }

    @Test func listIsLazy() {
        _ = TestHost(List {
            ForEach(0..<1000, id: \.self) { LazyRow(index: $0) }
        }, size: CGSize(width: 300, height: 200))
        #expect(Counter["LazyRow"] < 60)
    }

    @Test func scrollViewReaderScrollsToRow() {
        struct Screen: View {
            var body: some View {
                ScrollViewReader { proxy in
                    VStack {
                        Button("Jump") { proxy.scrollTo(700, anchor: .top) }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<1000, id: \.self) { LazyRow(index: $0) }
                            }
                        }
                    }
                }
            }
        }
        let host = TestHost(Screen(), size: CGSize(width: 300, height: 300))
        #expect(!host.texts.contains("row 700"))
        host.tap("Jump")
        host.flush()
        #expect(host.texts.contains("row 700"))
        let scroll = host.allViews.first { if case .scrollView = $0.content { return true }; return false }!
        guard case .scrollView(let resolved) = scroll.content else { return }
        #expect(resolved.requestedOffset?.y == 14_000)
    }
}
