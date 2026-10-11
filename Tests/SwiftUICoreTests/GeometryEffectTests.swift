import Foundation
import Observation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

/// Moves the view sideways by `amount` (animatable).
struct Slide: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount, y: 0))
    }
}

@Observable
final class SlideModel { var amount: CGFloat = 0 }

@MainActor
@Suite(.serialized)
struct GeometryEffectTests {
    private func projections(_ host: TestHost) -> [ProjectionTransform] {
        host.allViews.compactMap { if case .effect(.projection(let p)) = $0.content { return p } else { return nil } }
    }

    @Test func projectionTransformAlgebra() {
        let t = ProjectionTransform(CGAffineTransform(translationX: 10, y: 5).scaledBy(x: 2, y: 2))
        #expect(t.isAffine && !t.isIdentity)
        #expect(t.apply(to: CGPoint(x: 1, y: 1)) == CGPoint(x: 12, y: 7))
        #expect(t.concatenating(t.inverted()).isIdentity)
    }

    @Test func rotation3DAboutTheVerticalAxisMirrorsAtHalfTurn() {
        let effect = _Rotation3DEffect(angle: .degrees(180), axis: (x: 0, y: 1, z: 0))
        let size = CGSize(width: 100, height: 40)
        let m = effect.effectValue(size: size)
        let left = m.apply(to: CGPoint(x: 0, y: 10))
        #expect(abs(left.x - 100) < 1e-6 && abs(left.y - 10) < 1e-6)
        // At a quarter turn the near edge grows and the far edge shrinks (perspective).
        let quarter = _Rotation3DEffect(angle: .degrees(45), axis: (x: 0, y: 1, z: 0)).effectValue(size: size)
        #expect(!quarter.isAffine)
        let center = quarter.apply(to: CGPoint(x: 50, y: 20))
        #expect(abs(center.x - 50) < 1e-6 && abs(center.y - 20) < 1e-6)
        #expect(_Rotation3DEffect(angle: .zero, axis: (x: 1, y: 0, z: 0)).effectValue(size: size).isIdentity)
    }

    @Test func rotation3DEffectRendersAProjection() {
        let host = TestHost(Text("Card").rotation3DEffect(.degrees(30), axis: (x: 1, y: 0, z: 0)))
        let p = projections(host)
        #expect(p.count == 1 && !p[0].isAffine)
    }

    @Test func customGeometryEffectAnimatesItsData() {
        let model = SlideModel()
        struct Screen: View {
            let model: SlideModel
            var body: some View { Text("Box").modifier(Slide(amount: model.amount)) }
        }
        let host = TestHost(Screen(model: model))
        #expect(projections(host).first?.m31 == 0)
        withAnimation(.linear(duration: 1)) { model.amount = 100 }
        host.flush()
        host.advance(by: 0.5)
        let mid = projections(host).first!.m31
        #expect(mid > 40 && mid < 60)
        host.finishAnimations()
        #expect(projections(host).first?.m31 == 100)
    }

    @Test func scaleAndRotationTakeAnAnchor() {
        let host = TestHost(VStack {
            Text("A").scaleEffect(2, anchor: .topLeading)
            Text("B").rotationEffect(.degrees(10), anchor: .bottom)
            Text("C").scaleEffect(CGSize(width: 1, height: 3))
        })
        let anchors: [UnitPoint] = host.allViews.compactMap {
            if case .effect(.transform(_, _, _, let anchor)) = $0.content { return anchor } else { return nil }
        }
        #expect(anchors == [.topLeading, .bottom, .center])
    }

    @Test func transformAndProjectionEffects() {
        let host = TestHost(VStack {
            Text("A").transformEffect(CGAffineTransform(translationX: 3, y: 4))
            Text("B").projectionEffect(ProjectionTransform(CGAffineTransform(scaleX: 2, y: 2)))
        })
        let p = projections(host)
        #expect(p.count == 2 && p[0].m31 == 3 && p[0].m32 == 4 && p[1].m11 == 2)
    }

    /// Reference values from Apple SwiftUI's `_Rotation3DEffect.effectValue(size: 120×80)`.
    @Test func rotation3DMatchesSwiftUI() {
        let cases: [(_Rotation3DEffect, [CGFloat])] = [
            (.init(angle: .degrees(45), axis: (0, 1, 0)), [1.0607, 0.2357, 0.005893, 0, 1, 0, -3.6396, -14.1421, 0.6464]),
            (.init(angle: .degrees(50), axis: (1, 0, 0)), [1, 0, 0, -0.3830, 0.3874, -0.006384, 15.3209, 24.5024, 1.2553]),
            (.init(angle: .degrees(40), axis: (1, 1, 0), anchor: .leading, perspective: 0.6), [0.8830, 0.2079, 0.002273, 0.1170, 0.7921, -0.002273, -4.6791, 8.3153, 1.0909]),
            (.init(angle: .degrees(180), axis: (0, 1, 0)), [-1, 0, 0, 0, 1, 0, 120, 0, 1]),
            (.init(angle: .degrees(30), axis: (0, 0, 1), anchor: .topLeading, anchorZ: 10), [0.8660, 0.5, 0, -0.5, 0.8660, 0, 0, 0, 1.0833]),
        ]
        for (effect, expected) in cases {
            let m = effect.effectValue(size: CGSize(width: 120, height: 80))
            let actual = [m.m11, m.m12, m.m13, m.m21, m.m22, m.m23, m.m31, m.m32, m.m33]
            for (a, e) in zip(actual, expected) {
                #expect(abs(a - e) < 0.0005 * max(1, abs(e)), "\(actual) vs \(expected)")
            }
        }
    }
}
