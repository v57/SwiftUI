import Foundation
import Observation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class ScrollLog {
    var events: [String] = []
}

@MainActor
@Suite(.serialized)
struct ScrollFeatureTests {
    private func scrollNode(_ host: TestHost) -> HeadlessView {
        host.allViews.first { if case .scrollView = $0.content { true } else { false } }!
    }

    @Test func contentMarginsInsetScrollContent() {
        let host = TestHost(
            ScrollView { Color.red.frame(height: 50) }.contentMargins(10).frame(width: 200, height: 100),
            size: CGSize(width: 200, height: 100)
        )
        let fill = host.allViews.first { if case .color = $0.content { true } else { false } }!
        #expect(fill.frame == CGRect(x: 10, y: 10, width: 180, height: 50))
        guard case .scrollView(let model) = scrollNode(host).content else { Issue.record("no scroll view"); return }
        #expect(model.contentSize.height + model.contentOrigin.y == 70)
    }

    @Test func scrollConfigurationReachesScrollView() {
        let host = TestHost(
            ScrollView { Text("x") }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom)
                .scrollClipDisabled(),
            size: CGSize(width: 100, height: 100)
        )
        guard case .scrollView(let model) = scrollNode(host).content else { Issue.record("no scroll view"); return }
        #expect(model.verticalIndicator == .hidden && model.horizontalIndicator == .hidden)
        #expect(model.verticalBounce == .basedOnSize)
        #expect(model.initialAnchor == .bottom)
        #expect(!model.clipsContent)
    }

    @Test func scrollTransitionFollowsViewport() {
        let host = TestHost(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<4) { index in
                        Color.blue.frame(height: 100)
                            .scrollTransition { effect, phase in effect.opacity(phase.isIdentity ? 1 : 0) }
                    }
                }
            }
            .frame(width: 100, height: 200),
            size: CGSize(width: 100, height: 200)
        )
        func opacities() -> [Double] {
            host.allViews.compactMap { if case .effect(.opacity(let value)) = $0.content { value } else { nil } }
        }
        #expect(opacities() == [1, 1, 0, 0])
        host.scroll(to: CGPoint(x: 0, y: 50))
        // Rows half out of the viewport are half way through their transition.
        #expect(opacities() == [0.5, 1, 0.5, 0])
    }

    @Test func scrollVisibilityAndTargetsAreReported() {
        let log = ScrollLog()
        let host = TestHost(
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        Color.blue.frame(height: 100)
                            .onScrollVisibilityChange { visible in log.events.append("\(index) \(visible)") }
                    }
                }
            }
            .onScrollTargetVisibilityChange(idType: Int.self) { ids in log.events.append("targets \(ids)") }
            .frame(width: 100, height: 200),
            size: CGSize(width: 100, height: 200)
        )
        host.scroll(to: CGPoint(x: 0, y: 1))  // reports geometry after the first layout
        #expect(log.events.contains("0 true") && log.events.contains("1 true") && !log.events.contains("2 true"))
        #expect(log.events.contains("targets [0, 1]"))
        log.events.removeAll()
        host.scroll(to: CGPoint(x: 0, y: 200))
        #expect(log.events.contains("0 false") && log.events.contains("2 true") && log.events.contains("3 true"))
        #expect(log.events.contains("targets [2, 3]"))
    }

    @Test func pagingSnapsToPagesAndPhasesAreReported() {
        let log = ScrollLog()
        let host = TestHost(
            ScrollView { Color.red.frame(height: 1000) }
                .scrollTargetBehavior(.paging)
                .onScrollPhaseChange { old, new in log.events.append("\(old)->\(new)") }
                .frame(width: 100, height: 200),
            size: CGSize(width: 100, height: 200)
        )
        let actions = scrollNode(host).node!.actions
        #expect(actions.scrollSnapTarget?(CGPoint(x: 0, y: 290)) == CGPoint(x: 0, y: 200))
        #expect(actions.scrollSnapTarget?(CGPoint(x: 0, y: 310)) == CGPoint(x: 0, y: 400))
        #expect(actions.scrollSnapTarget?(CGPoint(x: 0, y: 950)) == CGPoint(x: 0, y: 800))
        actions.scrollPhase?(.interacting)
        actions.scrollPhase?(.idle)
        #expect(log.events == ["idle->interacting", "interacting->idle"])
    }

    @Test func visualEffectUsesGeometry() {
        let host = TestHost(
            Color.red.frame(width: 50, height: 40).visualEffect { effect, proxy in effect.offset(y: proxy.size.height) },
            size: CGSize(width: 100, height: 100)
        )
        let transforms = host.allViews.compactMap { view -> CGSize? in
            if case .effect(.transform(let offset, _, _)) = view.content { return offset } else { return nil }
        }
        #expect(transforms == [CGSize(width: 0, height: 40)])
    }
}
