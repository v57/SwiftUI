import Foundation
import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@MainActor
@Suite(.serialized)
struct DynamicTypeTests {
    @Test func textStylesScaleWithDynamicType() throws {
        let host = TestHost(VStack {
            Text("Default")
            Text("Large").dynamicTypeSize(.accessibility1)
            Text("Fixed").font(.system(size: 13)).dynamicTypeSize(.accessibility1)
            Text("Clamped").dynamicTypeSize(...DynamicTypeSize.xxLarge).dynamicTypeSize(.accessibility3)
        })
        let normal = try #require(host.view(withText: "Default")).frame.height
        let large = try #require(host.view(withText: "Large")).frame.height
        let fixed = try #require(host.view(withText: "Fixed")).frame.height
        let clamped = try #require(host.view(withText: "Clamped")).frame.height
        #expect(large > normal * 1.5)
        #expect(fixed == normal)
        #expect(clamped > normal && clamped < large)
    }

    @Test func scaledMetricFollowsDynamicType() throws {
        struct Box: View {
            @ScaledMetric var side: CGFloat = 20
            var body: some View { Color.red.frame(width: side, height: side) }
        }
        let host = TestHost(VStack { Box(); Box().dynamicTypeSize(.xxxLarge) })
        let boxes = host.allViews.filter { if case .color = $0.content { true } else { false } }.map(\.frame.width).sorted()
        #expect(boxes.first == 20)
        #expect((boxes.last ?? 0) > 26)
    }

    @Test func fontScaleMapsToNearestSize() {
        #expect(DynamicTypeSize(fontScale: 1) == .large)
        #expect(DynamicTypeSize(fontScale: 1.3) == .xxxLarge)
        #expect(DynamicTypeSize(fontScale: 0.89) == .small)
        #expect(DynamicTypeSize.accessibility2.isAccessibilitySize)
    }
}
