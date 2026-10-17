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

    /// Building one item of a long page sends the backend that item's views only: the renderer
    /// diffs a container's children and replaces the changed range, not the whole list.
    @Test func buildingOneItemTouchesOnlyItsViews() {
        let rows = makeScalingRows(500)
        let states = (0..<500).map { ScalingItemState(isBuilt: $0 % 2 == 0) }
        let host = TestHost(ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<rows.count, id: \.self) { ScalingLazyItem(state: states[$0], row: rows[$0], index: $0) }
            }
        }, size: CGSize(width: 600, height: 800))
        host.tracer.isRecording = false
        let scroll = host.allViews.first { if case .scrollView = $0.content { true } else { false } }!
        let builtViews = scroll.children.count
        #expect(builtViews > 2000)

        host.tracer.resetCounters()
        states[251].isBuilt = true
        host.flush()
        let added = scroll.children.count - builtViews
        #expect(added > 0)
        #expect(host.tracer.counters.childOperations == added)
        // The backend's list is the render tree's, in order.
        let expected = scroll.node!.platformChildren.map { ObjectIdentifier($0.handle!) }
        #expect(scroll.children.map(ObjectIdentifier.init) == expected)

        host.tracer.resetCounters()
        states[100].isBuilt = false
        host.flush()
        #expect(host.tracer.counters.childOperations < 40)
        #expect(scroll.children.map(ObjectIdentifier.init) == scroll.node!.platformChildren.map { ObjectIdentifier($0.handle!) })
    }
}
