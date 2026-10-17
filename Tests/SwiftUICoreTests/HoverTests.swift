import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

/// Which rows are hovered, as `onHover` reports it.
@MainActor
final class HoverLog {
    var hovered: Set<Int> = []
    var events = 0
    func set(_ index: Int, _ hovering: Bool) {
        events += 1
        if hovering { hovered.insert(index) } else { hovered.remove(index) }
    }
}

struct HoverRow: View {
    let index: Int
    let log: HoverLog
    var body: some View {
        Text("row \(index)")
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .onHover { log.set(index, $0) }
    }
}

/// Hover is hit-tested only when the pointer has rested and nothing has scrolled for 0.1 s, or on a
/// click, and only against the hover regions (never a walk of every view).
@MainActor
@Suite(.serialized)
struct HoverTests {
    func page(_ log: HoverLog, rows: Int = 500) -> TestHost {
        let host = TestHost(ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { HoverRow(index: $0, log: log) }
            }
        }, size: CGSize(width: 400, height: 400))
        host.tracer.isRecording = false
        return host
    }

    @Test func hoverWaitsForThePointerToRest() {
        let log = HoverLog()
        let host = page(log)
        host.tracer.resetCounters()
        host.movePointer(to: CGPoint(x: 100, y: 20))
        host.wait(0.05)
        #expect(log.hovered.isEmpty)
        // Moving again restarts the wait.
        host.movePointer(to: CGPoint(x: 100, y: 60))
        host.wait(0.09)
        #expect(log.hovered.isEmpty)
        #expect(host.tracer.counters.hitTestVisits == 0)
        host.wait(0.02)
        #expect(log.hovered == [1])
        // One pass over the hover regions (the 500 rows), not over every view on the page.
        #expect(host.tracer.counters.hitTestVisits == 500)
        #expect(host.allViews.count > 1000)
    }

    @Test func scrollingUnderARestingPointerHitTestsOnceItRests() {
        let log = HoverLog()
        let host = page(log)
        host.movePointer(to: CGPoint(x: 100, y: 60))
        host.wait(0.2)
        #expect(log.hovered == [1])
        host.tracer.resetCounters()
        // Half a second of scrolling, 10pt a frame: nothing is hit-tested meanwhile.
        host.scroll(by: CGPoint(x: 0, y: 10), frames: 60)
        #expect(host.tracer.counters.hitTestVisits == 0)
        #expect(log.hovered == [1])
        host.wait(0.11)
        // 600pt down: the pointer is over row 16.
        #expect(log.hovered == [16])
        #expect(host.tracer.counters.hitTestVisits == 500)
    }

    @Test func aClickHitTestsAtOnce() {
        let log = HoverLog()
        let host = page(log)
        host.movePointer(to: CGPoint(x: 100, y: 100))
        #expect(log.hovered.isEmpty)
        host.pressPointer(at: CGPoint(x: 100, y: 100))
        #expect(log.hovered == [2])
    }

    @Test func leavingAHoveredViewIsImmediate() {
        let log = HoverLog()
        let host = page(log)
        host.movePointer(to: CGPoint(x: 100, y: 60))
        host.wait(0.2)
        #expect(log.hovered == [1])
        host.movePointer(to: CGPoint(x: 100, y: 140))
        #expect(log.hovered.isEmpty)
        host.wait(0.2)
        #expect(log.hovered == [3])
        host.pointerExited()
        #expect(log.hovered.isEmpty)
    }

    /// In a lazy stack only built rows are hover regions, so a hit test visits what shows.
    @Test func lazyRowsBoundTheHitTest() {
        let log = HoverLog()
        let host = TestHost(ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<10_000, id: \.self) { HoverRow(index: $0, log: log) }
            }
        }, size: CGSize(width: 400, height: 400))
        host.tracer.isRecording = false
        host.movePointer(to: CGPoint(x: 100, y: 60))
        host.scroll(by: CGPoint(x: 0, y: 25), frames: 400)
        host.tracer.resetCounters()
        host.wait(0.11)
        // 10,000pt down: row 251 is under the pointer.
        #expect(log.hovered == [251])
        #expect(host.tracer.counters.hitTestVisits <= 30)
    }
}
