import Foundation
import Observation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

// Work must scale with what changed or what shows, never with everything built. These tests count
// the work (rule evaluations, layout, render updates, spacing, hit-test visits) on long synthetic
// pages shaped like the ComponentKit catalog: hundreds of cards from one ForEach, and a page of many
// distinct heavy views.

@Observable @MainActor
final class ScalingRow {
    var title: String
    init(_ title: String) { self.title = title }
}

/// A card like the catalog's repository cards: a header row, a meta line and a few rows of chips.
struct ScalingCard: View {
    let row: ScalingRow
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(row.title).font(.headline)
                Spacer()
                Text("\(index * 7 % 40) changes").font(.caption)
            }
            Text("main · 3 ahead · updated 2 min ago").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { chip in
                    Text("tag\(chip)").padding(.horizontal, 6).background(Capsule().fill(Color.blue.opacity(0.2)))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
    }
}

/// A lazily built item, like ComponentKit's lazy stack items: a placeholder until built.
@Observable @MainActor
final class ScalingItemState {
    var isBuilt: Bool
    init(isBuilt: Bool) { self.isBuilt = isBuilt }
}

struct ScalingLazyItem: View {
    let state: ScalingItemState
    let row: ScalingRow
    let index: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.isBuilt { ScalingCard(row: row, index: index) }
        }
        .frame(maxWidth: .infinity, minHeight: state.isBuilt ? nil : 96, alignment: .topLeading)
    }
}

@MainActor
func makeScalingRows(_ count: Int) -> [ScalingRow] {
    (0..<count).map { ScalingRow("Repository \($0)") }
}

@MainActor
@Suite(.serialized)
struct ScalingTests {
    /// Spacing is computed once per layout computer: a container's spacing is the union of its
    /// children's, and computing it on every query re-walked whole subtrees (a 500-card page took
    /// minutes to scroll).
    @Test func spacingIsComputedOncePerComputer() {
        let rows = makeScalingRows(300)
        let host = TestHost(ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<rows.count, id: \.self) { ScalingCard(row: rows[$0], index: $0) }
            }
        }, size: CGSize(width: 600, height: 800))
        host.tracer.isRecording = false
        let initial = host.tracer.counters.spacingComputations
        // Every computer at most once: well under the number of attributes on the page.
        #expect(initial > 0)
        #expect(initial < host.graph.graph.liveAttributeCount / 4)

        // One card's title changes: new computers along its path, the 299 others are cached.
        host.tracer.resetCounters()
        rows[150].title = "Renamed repository"
        host.flush()
        #expect(host.tracer.counters.spacingComputations < 40)
    }

    /// Building one item of a long page touches that item: each item of a long stack starts its own
    /// space (a container view), so the items below move as a whole instead of every view in them
    /// being placed and framed again, and the renderer sends the backend the changed range only.
    @Test func buildingOneItemTouchesOnlyThatItem() {
        let rows = makeScalingRows(500)
        let states = (0..<500).map { ScalingItemState(isBuilt: $0 % 2 == 0) }
        let host = TestHost(ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<rows.count, id: \.self) { ScalingLazyItem(state: states[$0], row: rows[$0], index: $0) }
            }
        }, size: CGSize(width: 600, height: 800))
        host.tracer.isRecording = false
        let scroll = host.allViews.first { if case .scrollView = $0.content { true } else { false } }!
        let builtViews = scroll.allDescendants.count
        #expect(builtViews > 2000)

        host.tracer.resetCounters()
        let evaluationsBefore = host.graph.graph.evaluationCount
        states[251].isBuilt = true
        host.flush()
        let c = host.tracer.counters
        let evaluations = host.graph.graph.evaluationCount - evaluationsBefore
        print("build one item: evaluations \(evaluations) body \(c[.body]) sizeThatFits \(c[.sizeThatFits]) placement \(c[.placement]) geometry \(c[.geometry]) renderFrame \(c[.renderFrame]) renderInsert \(c[.renderInsert])")
        let added = scroll.allDescendants.count - builtViews
        #expect(added == c[.renderInsert])
        #expect(host.tracer.counters.childOperations == added)
        // Below the item: 248 items move (one frame each); nothing inside them is placed again.
        #expect(c[.placement] < 40)
        #expect(c[.renderFrame] < 300)
        #expect(evaluations < 1500)
        // Every view still sits where an unisolated layout puts it: the built card right below its
        // neighbour, and the last card at the end of the content.
        let card = host.view(withText: "Repository 251")!
        let previous = host.view(withText: "Repository 250")!
        #expect(card.absoluteFrame.minY > previous.absoluteFrame.maxY)
        // The backend's lists are the render tree's, in order.
        func matchesRenderTree(_ view: HeadlessView) -> Bool {
            guard let node = view.node else { return true }
            let expected = node.platformChildren.compactMap { $0.handle.map(ObjectIdentifier.init) }
            return view.children.map(ObjectIdentifier.init) == expected && view.children.allSatisfy(matchesRenderTree)
        }
        #expect(matchesRenderTree(scroll))

        host.tracer.resetCounters()
        states[100].isBuilt = false
        host.flush()
        #expect(host.tracer.counters.childOperations < 40)
        #expect(matchesRenderTree(scroll))
    }

    /// Work per scroll step of a lazy stack, from the middle of `rows` rows.
    struct ScrollWork {
        var evaluations = 0
        var listVisits = 0
        var layout = 0
        var render = 0
    }

    func lazyScrollWork(rows: Int, steps: Int = Int(ProcessInfo.processInfo.environment["LAZY_STEPS"] ?? "40")!) -> ScrollWork {
        let host = TestHost(ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { LazyRow(index: $0) }
            }
        }, size: CGSize(width: 300, height: 400))
        host.tracer.isRecording = false
        // Start mid-list: every row above is unmeasured (estimated) and every row below too.
        host.scroll(to: CGPoint(x: 0, y: CGFloat(rows) * 10))
        host.tracer.resetCounters()
        let before = host.graph.graph.evaluationCount
        let scroll = host.allViews.first { if case .scrollView = $0.content { true } else { false } }!
        let start = Date()
        for _ in 0..<steps {
            let offset = scroll.node!.contentOffset
            scroll.node!.actions.scrolled?(CGPoint(x: 0, y: offset.y + 7))
            host.flush()
        }
        print("lazy scroll \(rows) rows: \(String(format: "%.3f", Date().timeIntervalSince(start) / Double(steps) * 1000)) ms per step")
        let counters = host.tracer.counters
        return ScrollWork(
            evaluations: (host.graph.graph.evaluationCount - before) / steps,
            listVisits: counters.listElementVisits / steps,
            layout: (counters[.sizeThatFits] + counters[.placement] + counters[.geometry]) / steps,
            render: (counters[.renderInsert] + counters[.renderRemove] + counters[.renderFrame] + counters[.renderContent]) / steps)
    }

    /// Scrolling a lazy stack costs the same with 1,000 rows as with 100,000: offsets come from
    /// prefix sums, the flattened list is kept between steps, and only rows that show are touched.
    @Test func lazyStackScrollWorkIsIndependentOfRowCount() {
        let small = lazyScrollWork(rows: 1_000)
        let large = lazyScrollWork(rows: 100_000)
        print("lazy scroll work per step: 1k \(small), 100k \(large)")
        #expect(large.listVisits <= small.listVisits + 10)
        #expect(large.listVisits < 60)
        #expect(large.evaluations <= small.evaluations + small.evaluations / 10 + 5)
        #expect(large.layout <= small.layout + 2)
        #expect(large.render <= small.render + 2)
    }

    /// A text is measured once per proposed width: stacks probe each width with many heights,
    /// which don't change a text's size unless it has to drop lines.
    @Test func textIsMeasuredOncePerWidth() {
        let rows = makeScalingRows(40)
        let host = TestHost(ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<rows.count, id: \.self) { ScalingCard(row: rows[$0], index: $0).frame(minHeight: 60) }
            }
        }, size: CGSize(width: 600, height: 800))
        let texts = host.allViews.filter { $0.text != nil }.count
        #expect(texts == 40 * 7)
        // A handful per text: its widths (0, ∞, its share, its final width), one line's height and
        // the one-line size at a squeezed width (was 3,000 for these 280 texts: every height probe
        // measured again).
        #expect(host.backend.textMeasurements <= texts * 6)
    }
}
