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
}
