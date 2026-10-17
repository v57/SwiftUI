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
}
