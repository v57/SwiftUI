import Foundation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
@Suite(.serialized)
struct AccessibilityTests {
    @Test func modifiersCombineOnTheNearestView() throws {
        let host = TestHost(
            Text("5").accessibilityLabel("Count").accessibilityValue("five").accessibilityHint("Items").accessibilityAddTraits(.isButton)
        )
        let properties = try #require(host.view(withText: "5")?.accessibility)
        #expect(properties.label == "Count" && properties.value == "five" && properties.hint == "Items")
        #expect(properties.traits == .isButton)
    }

    @Test func stacksBecomeGroupElements() throws {
        let host = TestHost(VStack { Text("A"); Text("B") }.accessibilityElement(children: .combine).accessibilityLabel("Pair"))
        let group = try #require(host.allViews.first { $0.accessibility?.children == .combine })
        #expect(group.content == .effect(.group))
        #expect(group.accessibility?.label == "Pair")
        #expect(host.view(withText: "A")?.accessibility == nil)  // consumed by the group
    }

    @Test func actionsUseTheLatestHandlers() throws {
        let log = ScrollLog()
        struct Screen: View {
            let log: ScrollLog
            @State var count = 0
            var body: some View {
                Text("n \(count)")
                    .accessibilityAction(named: "Bump") { count += 1; log.events.append("bump \(count)") }
                    .accessibilityAdjustableAction { direction in log.events.append("\(direction)") }
            }
        }
        let host = TestHost(Screen(log: log))
        func perform(_ kind: AccessibilityActionHandler.Kind) {
            host.allViews.compactMap(\.accessibility).flatMap(\.actions).first { $0.kind == kind }?.perform()
            host.flush()
        }
        perform(.named("Bump"))
        perform(.named("Bump"))
        perform(.adjust(.decrement))
        #expect(log.events == ["bump 1", "bump 2", "decrement"])
        #expect(host.texts == ["n 2"])
    }

    @Test func representationAndHidden() throws {
        let host = TestHost(VStack {
            Color.red.frame(width: 10, height: 10).accessibilityRepresentation { Button("Close") {} }
            Text("secret").accessibilityHidden(true)
        })
        let represented = try #require(host.allViews.first { $0.accessibility?.label == "Close" })
        #expect(represented.accessibility?.traits.contains(.isButton) == true)
        #expect(host.view(withText: "secret")?.accessibility?.isHidden == true)
    }
}
