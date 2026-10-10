import Foundation
import Observation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class AnimModel {
    var wide = false
    var show = true
    var progress = 0.0
    var color = Color.red
    var other = 0
}

struct Bar: View {
    let model: AnimModel
    var body: some View {
        Color.blue.frame(width: model.wide ? 200 : 100, height: 20)
    }
}

/// A custom Animatable view: body is re-evaluated with interpolated data each frame.
struct ProgressLabel: View, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        let _ = Counter.hit("ProgressLabel")
        Text("p=\(Int(progress * 100))")
    }
}

@MainActor
@Suite(.serialized)
struct AnimationTests {
    init() { Counter.reset() }

    private func blueFrame(_ host: TestHost) -> CGRect {
        host.allViews.first { if case .color = $0.content { return true }; return false }!.frame
    }

    @Test func curvesSampleCorrectly() {
        #expect(Animation.linear(duration: 1).sample(at: 0.5).progress == 0.5)
        #expect(Animation.linear(duration: 1).sample(at: 1.5) == (1, true))
        let ease = Animation.easeInOut(duration: 1).sample(at: 0.25).progress
        #expect(ease < 0.25 && ease > 0)
        let spring = Animation.spring(response: 0.5, dampingFraction: 0.5)
        let peak = stride(from: 0.0, to: 1, by: 0.01).map { spring.sample(at: $0).progress }.max()!
        #expect(peak > 1) // underdamped springs overshoot
        #expect(Animation.linear(duration: 1).delay(0.5).sample(at: 0.5).progress == 0)
        #expect(Animation.linear(duration: 1).repeatForever().sample(at: 100).finished == false)
    }

    @Test func withoutAnimationChangesApplyImmediately() {
        let model = AnimModel()
        let host = TestHost(Bar(model: model))
        model.wide = true
        host.flush()
        #expect(blueFrame(host).width == 200)
        #expect(!host.graph.hasActiveAnimations)
    }

    @Test func withAnimationInterpolatesFrames() {
        let model = AnimModel()
        let host = TestHost(Bar(model: model))
        withAnimation(.linear(duration: 1)) { model.wide = true }
        host.flush()
        #expect(blueFrame(host).width == 100) // presented value starts at the old frame
        host.advance(by: 0.5)
        #expect(abs(blueFrame(host).width - 150) < 0.5)
        host.advance(by: 0.6)
        #expect(blueFrame(host).width == 200)
        #expect(!host.graph.hasActiveAnimations)
        // Layout ran once; animation frames are render-only.
        #expect(host.tracer.count(.renderFrame) == 1)
    }

    @Test func animationModifierScopesToValue() {
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                VStack {
                    Color.blue.frame(width: model.wide ? 200 : 100, height: 20)
                        .animation(.linear(duration: 1), value: model.wide)
                    Text("other \(model.other)")
                }
            }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        model.wide = true
        host.flush()
        host.advance(by: 0.5)
        #expect(abs(blueFrame(host).width - 150) < 0.5)
        host.finishAnimations()
        model.other = 1 // value unchanged → not animated
        host.flush()
        #expect(!host.graph.hasActiveAnimations)
    }

    @Test func colorsInterpolate() {
        struct Screen: View {
            let model: AnimModel
            var body: some View { model.color.frame(width: 10, height: 10) }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        withAnimation(.linear(duration: 1)) { model.color = Color(red: 0, green: 0, blue: 1) }
        host.flush()
        host.advance(by: 0.5)
        guard case .color(let color) = host.allViews[0].content else { Issue.record("no color"); return }
        // Halfway from red to (0, 0, 1).
        #expect(color.red > 0.4 && color.red < 0.6)
        #expect(color.blue > 0.5 && color.blue < 0.75)
    }

    @Test func insertionAndRemovalTransitions() {
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                VStack {
                    if model.show {
                        Text("hello").transition(.opacity)
                    }
                    Text("tail")
                }
            }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        withAnimation(.linear(duration: 1)) { model.show = false }
        host.flush()
        // Removed view stays visible (ghost) while fading out.
        #expect(host.texts.contains("hello"))
        host.advance(by: 0.5)
        #expect(abs((host.view(withText: "hello")?.presentation.opacity ?? -1) - 0.5) < 0.01)
        host.finishAnimations()
        #expect(!host.texts.contains("hello"))

        withAnimation(.linear(duration: 1)) { model.show = true }
        host.flush()
        #expect(host.view(withText: "hello")?.presentation.opacity == 0)
        host.finishAnimations()
        #expect(host.view(withText: "hello")?.presentation.opacity == 1)
    }

    @Test func moveTransitionOffsetsBySize() {
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                if model.show { Color.red.frame(width: 100, height: 50).transition(.move(edge: .leading)) }
            }
        }
        let model = AnimModel()
        model.show = false
        let host = TestHost(Screen(model: model))
        withAnimation(.linear(duration: 1)) { model.show = true }
        host.flush()
        let view = host.allViews.first { $0.isFill }!
        #expect(view.presentation.offset.width == -100)
        host.advance(by: 0.5)
        #expect(abs(view.presentation.offset.width + 50) < 0.5)
    }

    @Test func customTransitionProtocolUsesPhaseEffects() {
        struct Shrink: Transition {
            func body(content: Content, phase: TransitionPhase) -> some View {
                content.scaleEffect(phase.isIdentity ? 1 : 0.5).opacity(phase.isIdentity ? 1 : 0)
                    .blur(radius: phase == .didDisappear ? 8 : 0)
            }
        }
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                if model.show { Text("hello").transition(Shrink()) }
            }
        }
        let model = AnimModel()
        model.show = false
        let host = TestHost(Screen(model: model))
        withAnimation(.linear(duration: 1)) { model.show = true }
        host.flush()
        let presentation = host.view(withText: "hello")?.presentation
        #expect(presentation?.opacity == 0)
        #expect(presentation?.scale == CGSize(width: 0.5, height: 0.5))
        host.finishAnimations()
        #expect(host.view(withText: "hello")?.presentation.isIdentity == true)
    }

    @Test func keyframeTimelineEvaluatesTracks() {
        struct Values { var scale = 1.0; var offset = 0.0 }
        let timeline = KeyframeTimeline(initialValue: Values()) {
            KeyframeTrack(\.scale) {
                LinearKeyframe(2.0, duration: 1)
                MoveKeyframe(5.0)
                LinearKeyframe(1.0, duration: 1)
            }
            KeyframeTrack(\.offset) {
                SpringKeyframe(10.0, duration: 0.5, spring: .smooth)
            }
        }
        #expect(timeline.duration == 2)
        #expect(timeline.value(time: 0).scale == 1)
        #expect(timeline.value(time: 0.5).scale == 1.5)
        #expect(timeline.value(time: 1).scale == 5)       // move jumps
        #expect(timeline.value(time: 1.5).scale == 3)
        #expect(timeline.value(time: 3).scale == 1)       // holds the last keyframe
        #expect(timeline.value(time: 0.25).offset > 0 && timeline.value(time: 0.25).offset < 10)
        #expect(timeline.value(time: 1).offset == 10)
        #expect(timeline.value(progress: 0.25).scale == 1.5)
    }

    @Test func keyframeAnimatorRunsOnTrigger() {
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                KeyframeAnimator(initialValue: 0.0, trigger: model.other) { value in
                    Text("v \(Int(value))")
                } keyframes: { _ in
                    LinearKeyframe(100.0, duration: 1)
                }
            }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        #expect(host.texts == ["v 0"])
        model.other = 1
        host.flush()
        host.advance(by: 0.5)
        #expect(host.texts == ["v 50"])
        host.finishAnimations()
        #expect(host.texts == ["v 0"])  // back at rest once the keyframes finish
        #expect(!host.graph.hasActiveAnimations)
    }

    @Test func phaseAnimatorViewCyclesPhasesOnTrigger() {
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                PhaseAnimator([0, 1, 2], trigger: model.other) { phase in Text("phase \(phase)") }
            }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        #expect(host.texts == ["phase 0"])
    }

    @Test func animatableViewBodyRunsPerFrame() {
        struct Screen: View {
            let model: AnimModel
            var body: some View { ProgressLabel(progress: model.progress) }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        Counter.reset()
        withAnimation(.linear(duration: 1)) { model.progress = 1 }
        host.flush()
        host.advance(by: 0.5)
        #expect(host.texts == ["p=50"])
        host.finishAnimations()
        #expect(host.texts == ["p=100"])
        #expect(Counter["ProgressLabel"] > 10)
    }

    @Test func completionRunsAfterAnimationsFinish() {
        let model = AnimModel()
        let host = TestHost(Bar(model: model))
        var completed = false
        withAnimation(.linear(duration: 0.5)) {
            model.wide = true
        } completion: {
            completed = true
        }
        host.flush()
        #expect(!completed)
        host.finishAnimations()
        #expect(completed)
    }

    @Test func animatableShapeStillAnimatesFrameAndColor() {
        // RoundedRectangle's corner radius animates per frame (Animatable); those per-frame updates
        // must not cancel the frame/color interpolation of the same node.
        struct Screen: View {
            let model: AnimModel
            var body: some View {
                RoundedRectangle(cornerRadius: model.wide ? 40 : 8)
                    .fill(model.wide ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 0, blue: 1))
                    .frame(width: model.wide ? 200 : 100, height: 80)
            }
        }
        let model = AnimModel()
        let host = TestHost(Screen(model: model))
        withAnimation(.linear(duration: 1)) { model.wide = true }
        host.flush()
        host.advance(by: 0.5)
        let shape = host.allViews.first { if case .shape = $0.content { return true }; return false }!
        #expect(abs(shape.frame.width - 150) < 1)
        guard case .shape(let resolved) = shape.content else { return }
        #expect(resolved.fill!.red > 0.3 && resolved.fill!.red < 0.7)
        host.finishAnimations()
        #expect(shape.frame.width == 200)
    }

    @Test func retargetingStartsFromPresentedValue() {
        let model = AnimModel()
        let host = TestHost(Bar(model: model))
        withAnimation(.linear(duration: 1)) { model.wide = true }
        host.flush()
        host.advance(by: 0.5)
        withAnimation(.linear(duration: 1)) { model.wide = false }
        host.flush()
        host.advance(by: 0.5)
        // Like SwiftUI, the interrupted animation keeps running underneath (measured on Apple's
        // SwiftUI: the value is back at the midpoint, 150, when the first animation ends).
        #expect(abs(blueFrame(host).width - 150) < 0.5)
    }
}
