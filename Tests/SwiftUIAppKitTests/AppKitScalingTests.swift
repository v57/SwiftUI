#if canImport(AppKit)
import AppKit
import Testing
import Observation
@testable import SwiftUIAppKit
import SwiftUI

@_silgen_name("thread_selfcounts") private func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32

/// Instructions the calling thread has retired (the same on any core and under any load).
private func threadInstructions() -> UInt64 {
    var counts: (instructions: UInt64, cycles: UInt64) = (0, 0)
    guard withUnsafeMutableBytes(of: &counts, { thread_selfcounts(1, $0.baseAddress!, $0.count) }) == 0 else { return 0 }
    return counts.instructions
}

@Observable @MainActor
final class AppKitLazyItemState {
    var isBuilt = false
}

/// A card like the catalog's long list: a header, a meta line and rows of chips.
struct AppKitBenchCard: View {
    let index: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text("Repository \(index)").font(.headline)
                Spacer()
                Text("\(index * 7 % 40) changes").font(.caption)
            }
            Text("main · 3 ahead · updated 2 min ago").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    Text("branch \(row)")
                    Spacer()
                    Text("\(row + index % 5)").padding(.horizontal, 6).background(Capsule().fill(Color.blue.opacity(0.2)))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
    }
}

/// A lazily built item, like ComponentKit's lazy stack items: a placeholder until built.
struct AppKitLazyItem: View {
    let state: AppKitLazyItemState
    let index: Int
    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.isBuilt { AppKitBenchCard(index: index) }
        }
        .frame(maxWidth: .infinity, minHeight: state.isBuilt ? nil : 140, alignment: .topLeading)
    }
}

@MainActor
@Suite(.serialized)
struct AppKitScalingTests {
    /// Scrolls a 500-card page on the AppKit backend the way the catalog's long list does: each
    /// step scrolls 150 pt, builds the card coming into view and lets go of one far above, then
    /// commits and lets Core Animation flush. `APPKIT_BENCH=1` prints the main thread's
    /// instructions per step by depth: a step deep in the page must cost what one at the top does.
    @Test func scrollingDeepCostsTheSameAsAtTheTop() {
        guard ProcessInfo.processInfo.environment["APPKIT_BENCH"] != nil else { return }
        let count = ProcessInfo.processInfo.environment["APPKIT_BENCH_ITEMS"].flatMap(Int.init) ?? 500
        let states = (0..<count).map { _ in AppKitLazyItemState() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { AppKitLazyItem(state: states[$0], index: $0) }
            }
        })
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 900)
        for index in 0..<8 { states[index].isBuilt = true }
        host.graph.update()
        CATransaction.flush()
        let scroll = descendants(of: host).compactMap { $0 as? NSScrollView }.first!
        var perStep: [UInt64] = []
        for step in 0..<(ProcessInfo.processInfo.environment["APPKIT_BENCH_STEPS"].flatMap(Int.init) ?? 300) {
            let start = threadInstructions()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(step + 1) * 150))
            scroll.reflectScrolledClipView(scroll.contentView)
            let built = 8 + step
            if built < states.count { states[built].isBuilt = true }
            if built - 16 >= 0 { states[built - 16].isBuilt = false }
            host.graph.update()
            window.displayIfNeeded()
            CATransaction.flush()
            perStep.append(threadInstructions() - start)
        }
        let chunks = stride(from: 0, to: perStep.count, by: 50).map { Array(perStep[$0..<min($0 + 50, perStep.count)]).sorted()[25] }
        print("appkit scroll: median instructions per step by 50 steps (k):", chunks.map { $0 / 1000 })
        #expect(chunks.last! < chunks.first! * 2)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
#endif
