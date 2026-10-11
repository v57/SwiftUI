import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
final class RetargetModel: ObservableObject { @Published var x: CGFloat = 0 }

@MainActor
struct RetargetTests {
    @Test func springFollowsRapidRetargets() {
        struct Screen: View {
            @ObservedObject var model: RetargetModel
            var body: some View { Color.red.frame(width: 10, height: 10).offset(x: model.x).frame(width: 400, alignment: .leading) }
        }
        let model = RetargetModel()
        let host = TestHost(Screen(model: model))
        var samples: [CGFloat] = []
        for i in 0..<50 {
            withAnimation(.spring(response: 0.25, dampingFraction: 1)) { model.x = CGFloat(i + 1) * 6 }
            host.flush()
            host.advance(by: 0.01)
            if i % 10 == 9 { samples.append(host.allViews.first { if case .color = $0.content { true } else { false } }!.absoluteFrame.minX) }
        }
        // Retargeting a spring on every event keeps it moving (SwiftUI: 25, 81, 135, 193, 251
        // behind targets 60 … 300); restarting from rest would leave it far behind.
        #expect(samples.count == 5)
        for (index, sample) in samples.enumerated() {
            let target = CGFloat(index + 1) * 60
            #expect(sample > target - 50 && sample < target)
        }
    }
}
