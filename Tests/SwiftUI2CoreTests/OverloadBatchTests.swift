import Foundation
import Observation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@Observable
final class OverloadLog { var entries: [String] = [] }

@MainActor
@Suite(.serialized)
struct OverloadBatchTests {
    @Test func disabledGesturesDoNotFire() {
        let log = OverloadLog()
        struct Screen: View {
            let log: OverloadLog
            var body: some View {
                VStack {
                    Text("On").gesture(TapGesture().onEnded { log.entries.append("on") }, isEnabled: true)
                    Text("Off").gesture(TapGesture().onEnded { log.entries.append("off") }, isEnabled: false)
                    Text("Named").simultaneousGesture(TapGesture().onEnded { log.entries.append("named") }, name: "tap")
                }
            }
        }
        let host = TestHost(Screen(log: log))
        host.tap("On")
        host.tap("Named")
        #expect(log.entries == ["on", "named"])
        let off = host.view(withText: "Off")!
        #expect(off.superview.map { if case .effect(.group) = $0.content { true } else { false } } == true)
    }

    @Test func customFontsWidthAndCaps() {
        let font = Font.custom("Avenir Next", size: 17).width(.condensed).smallCaps().resolve()
        #expect(font.name == "Avenir Next" && font.size == 17 && font.width == Font.Width.condensed.value && font.caps == .smallCaps)
        let system = Font.system(size: 12).resolve()
        #expect(system.name == nil && system.weight == .regular)
        var env = EnvironmentValues()
        env.font = .body
        let host = TestHost(Text("Narrow").fontWidth(.compressed))
        _ = host
        let text = Text("Wide").fontWidth(.expanded).resolve(in: env)
        #expect(text.font.width == Font.Width.expanded.value)
    }

    @Test func partialListRowInsets() throws {
        let host = TestHost(
            List {
                Text("Default")
                Text("Flush").listRowInsets(.leading, 0)
                Text("Reset").listRowInsets(.leading, 0).listRowInsets(.leading, nil)
            },
            size: CGSize(width: 300, height: 300)
        )
        let normal = try #require(host.view(withText: "Default")).absoluteFrame
        let flush = try #require(host.view(withText: "Flush")).absoluteFrame
        let reset = try #require(host.view(withText: "Reset")).absoluteFrame
        #expect(flush.minX < normal.minX)
        #expect(reset.minX == normal.minX)
    }

    @Test func transformAnchorPreferenceCombinesWithInnerValues() {
        struct BoundsKey: PreferenceKey {
            static let defaultValue = 0
            static func reduce(value: inout Int, nextValue: () -> Int) { value += nextValue() }
        }
        struct Screen: View {
            @State var count = 0
            var body: some View {
                VStack {
                    Text("rects \(count)")
                    Color.red.frame(width: 30, height: 10)
                        .anchorPreference(key: BoundsKey.self, value: .bounds) { _ in 1 }
                        .padding(5)
                        .transformAnchorPreference(key: BoundsKey.self, value: .bounds) { value, _ in value += 1 }
                }
                .onPreferenceChange(BoundsKey.self) { count = $0 }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("rects 2"))
    }

    @Test func scrollViewCoordinateSpace() {
        struct Screen: View {
            @State var y: CGFloat = -1
            var body: some View {
                VStack {
                    Text("y \(Int(y))")
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.blue.frame(height: 50)
                            Color.red.frame(height: 20)
                                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .scrollView).minY }) { y = $0 }
                            Color.blue.frame(height: 400)
                        }
                    }
                    .frame(height: 100)
                }
            }
        }
        let host = TestHost(Screen())
        host.flush()
        #expect(host.texts.contains("y 50"))
        host.scroll(to: CGPoint(x: 0, y: 30))
        host.flush()
        #expect(host.texts.contains("y 20"))
    }

    @Test func colorEffectsAnimateAndRedactionMarksContent() {
        let model = SlideModel()
        struct Screen: View {
            let model: SlideModel
            var body: some View {
                VStack {
                    Color.red.frame(width: 10, height: 10).grayscale(model.amount / 100)
                    Group {
                        Text("Secret")
                        Text("Shown").unredacted()
                        Image(systemName: "star")
                    }
                    .redacted(reason: .placeholder)
                }
            }
        }
        let host = TestHost(Screen(model: model))
        func grayscale() -> Double? {
            host.allViews.lazy.compactMap { if case .effect(.colorFilter(.grayscale(let a))) = $0.content { return a } else { return nil } }.first
        }
        #expect(grayscale() == 0)
        withAnimation(.linear(duration: 1)) { model.amount = 100 }
        host.flush()
        host.advance(by: 0.5)
        let mid = grayscale() ?? -1
        #expect(mid > 0.3 && mid < 0.7)
        let texts: [ResolvedText] = host.allViews.compactMap { if case .text(let t) = $0.content { return t } else { return nil } }
        #expect(texts.first { $0.string == "Secret" }?.isRedacted == true)
        #expect(texts.first { $0.string == "Shown" }?.isRedacted == false)
        let image: ResolvedImage? = host.allViews.lazy.compactMap { if case .image(let i) = $0.content { return i } else { return nil } }.first
        #expect(image?.redactedColor != nil)
    }

    @Test func symbolModesEffectsAndContentTransitions() {
        let model = SlideModel()
        struct Screen: View {
            let model: SlideModel
            var body: some View {
                VStack {
                    Image(systemName: "cloud.sun").symbolRenderingMode(.hierarchical).foregroundStyle(.blue)
                    Image(systemName: "person.badge.plus").foregroundStyle(.green, .gray)
                    Image(systemName: "bell").symbolEffect(.bounce.up, value: model.amount)
                    Image(systemName: "wifi").symbolEffect(.variableColor.iterative, options: .repeat(3), isActive: model.amount > 0)
                    Text("\(Int(model.amount))").contentTransition(.numericText(countsDown: true))
                }
            }
        }
        let host = TestHost(Screen(model: model))
        func images() -> [ResolvedImage] { host.allViews.compactMap { if case .image(let i) = $0.content { return i } else { return nil } } }
        var all = images()
        #expect(all[0].renderingMode == .hierarchical && all[0].paletteColors.count == 1)
        #expect(all[1].renderingMode == .palette && all[1].paletteColors.count == 2)
        #expect(all[2].symbolEffects.first?.trigger == 0 && all[2].symbolEffects.first?.effect.options == ["up"])
        #expect(all[3].symbolEffects.first?.isActive == false && all[3].symbolEffects.first?.options.repeatCount == 3)
        model.amount = 1
        host.flush()
        all = images()
        #expect(all[2].symbolEffects.first?.trigger == 1)
        #expect(all[3].symbolEffects.first?.isActive == true)
        let text: ResolvedText? = host.allViews.lazy.compactMap { if case .text(let t) = $0.content { return t } else { return nil } }.first
        #expect(text?.contentTransition == .numericText(countsDown: true))
    }

    @Test func scopedAnimationAnimatesOnlyTheBody() {
        let model = SlideModel()
        struct Screen: View {
            let model: SlideModel
            var body: some View {
                Color.red
                    .frame(width: 10 + model.amount, height: 10)
                    .animation(.linear(duration: 1)) { $0.opacity(model.amount > 0 ? 0 : 1) }
            }
        }
        let host = TestHost(Screen(model: model))
        model.amount = 90
        host.flush()
        host.advance(by: 0.5)
        let opacity: Double? = host.allViews.lazy.compactMap { if case .effect(.opacity(let o)) = $0.content { return o } else { return nil } }.first
        #expect(opacity.map { $0 > 0.3 && $0 < 0.7 } == true)
        let color = host.allViews.first { if case .color = $0.content { true } else { false } }
        #expect(color?.frame.width == 100) // the content's frame change is not animated
    }

    @Test func timersColorsMixAndTabs() {
        let start = Date().addingTimeInterval(-65)
        #expect(Text(timerInterval: start...start.addingTimeInterval(3600), countsDown: false).plainString == "1:05")
        #expect(Text(timerInterval: start...start.addingTimeInterval(3600), pauseTime: start.addingTimeInterval(3700), countsDown: true).plainString == "0:00")
        #expect(Text(Date().addingTimeInterval(-3661), style: .timer).plainString == "1:01:01")
        #expect(Text(Date().addingTimeInterval(-150), style: .relative).plainString.hasPrefix("2 min"))
        #expect(Text(Date().addingTimeInterval(7300), style: .offset).plainString.hasPrefix("+2 hours"))
        let mixed = Color.black.mix(with: .white, by: 0.5).resolve(in: EnvironmentValues())
        #expect(abs(mixed.red - 0.5) < 0.01)
        struct Tabs: View {
            var body: some View {
                TabView {
                    Tab("First", systemImage: "1.circle") { Text("one") }
                    TabSection("More") { Tab("Second", systemImage: "2.circle") { Text("two") } }
                }
            }
        }
        let host = TestHost(Tabs())
        #expect(host.texts.contains("one"))
        let unavailable = TestHost(ContentUnavailableView.search(text: "kiwi"))
        #expect(unavailable.texts.contains("No Results"))
    }

    struct HalfLinear: CustomAnimation {
        func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
            time >= 2 ? nil : value.scaled(by: time / 2)
        }
    }

    struct Fade: ViewModifier {
        let amount: Double
        func body(content: Content) -> some View { content.opacity(amount).scaleEffect(amount) }
    }

    struct Order: LayoutValueKey { static let defaultValue = 0 }

    struct OrderedRow: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { CGSize(width: 100, height: 20) }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x = bounds.minX
            for subview in subviews.sorted(by: { $0[Order.self] < $1[Order.self] }) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .unspecified)
                x += 30
            }
        }
    }

    @Test func customAnimationsModifierTransitionsAndLayoutValues() {
        let model = SlideModel()
        struct Screen: View {
            let model: SlideModel
            var body: some View { Color.red.frame(width: 10 + model.amount, height: 10) }
        }
        let host = TestHost(Screen(model: model))
        withAnimation(Animation(HalfLinear())) { model.amount = 100 }
        host.flush()
        host.advance(by: 1)
        let width = host.allViews.first { if case .color = $0.content { true } else { false } }?.frame.width ?? 0
        #expect(width > 50 && width < 70)
        host.finishAnimations()

        let transition = AnyTransition.modifier(active: Fade(amount: 0.5), identity: Fade(amount: 1))
        #expect(transition.insertion.opacity == 0.5 && transition.insertion.scale == CGSize(width: 0.5, height: 0.5))

        let layoutHost = TestHost(OrderedRow {
            Text("B").layoutValue(key: Order.self, value: 2)
            Text("A").layoutValue(key: Order.self, value: 1)
        })
        let a = layoutHost.view(withText: "A")!.absoluteFrame.minX
        let b = layoutHost.view(withText: "B")!.absoluteFrame.minX
        #expect(a < b)
    }

    @Test func formattedTextUsesTheEnvironmentLocaleAndFormsLabelRows() {
        var english = EnvironmentValues()
        english.locale = Locale(identifier: "en_US")
        var german = EnvironmentValues()
        german.locale = Locale(identifier: "de_DE")
        #expect(Text(0.5, format: .percent).resolve(in: english).string == "50%")
        #expect(Text(0.5, format: .percent).resolve(in: german).string == "50\u{00A0}%")
        struct Screen: View {
            @State var name = "Ada"
            var body: some View {
                Form {
                    TextField("Name", text: $name, prompt: Text("Your name"))
                    LabeledContent("Share", value: 0.25, format: .percent)
                }
                .formStyle(.grouped)
                .environment(\.locale, Locale(identifier: "en_US"))
            }
        }
        let host = TestHost(Screen())
        #expect(host.texts.contains("Name") && !host.texts.contains("Your name"))
        #expect(host.texts.contains("25%"))
    }

    @Test func buttonShapesAndSizing() {
        let host = TestHost(VStack {
            Button("Wide") {}.buttonSizing(.flexible).frame(width: 200)
            Button("O") {}.buttonBorderShape(.circle)
            Button("Cap") {}.buttonBorderShape(.capsule)
        })
        let buttons: [(ResolvedButton, CGRect)] = host.allViews.compactMap { if case .button(let b) = $0.content { return (b, $0.frame) } else { return nil } }
        #expect(buttons.count == 3)
        #expect(buttons[0].1.width == 200)
        #expect(buttons[1].1.width == buttons[1].1.height && buttons[1].0.borderShape == .circle)
        #expect(buttons[2].0.borderShape == .capsule)
    }
}
