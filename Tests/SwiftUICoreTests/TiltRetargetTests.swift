import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
final class TiltModel: ObservableObject { @Published var p: CGFloat = 0 }

@MainActor
struct TiltRetargetTests {
    struct Screen: View {
        @ObservedObject var model: TiltModel
        var tilt = true
        var body: some View {
            Color.gray.frame(width: 100, height: 100)
                .rotation3DEffect(.degrees(tilt ? Double(model.p) * 8 : 0), axis: (x: 0, y: 1, z: 0), anchorZ: -8)
                .offset(x: model.p * 100)
                .frame(width: 400, height: 200)
        }
    }

    @Test(arguments: [true, false]) func offsetTracksWithTilt(tilt: Bool) {
        let model = TiltModel()
        let host = TestHost(Screen(model: model, tilt: tilt))
        var lags: [CGFloat] = []
        for i in 1...100 {
            withAnimation(.spring(response: 0.25, dampingFraction: 1)) { model.p = CGFloat(i) / 100 }
            if i % 2 == 0 { host.flush() }          // some events get their own update…
            host.advance(by: 1.0 / 120)             // …others land in a frame
            if i % 10 == 0 {
                let node = host.allViews.first { $0.frame.width == 100 }!
                lags.append(CGFloat(150 + i) - node.absoluteFrame.minX)
            }
        }
        // A spring retargeted on every event trails by a steady few points, with or without a 3D
        // effect on the same view (a non-interpolable projection used to restart the frame
        // animation from rest, so the offset fell far behind).
        #expect(lags.allSatisfy { $0 < 12 })

    }
}
