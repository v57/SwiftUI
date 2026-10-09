import Foundation
import Testing
import SwiftUI2Core
import SwiftUI2Headless

@MainActor
struct LayoutTests {
    @Test func textIsCenteredInHost() throws {
        let host = TestHost(Text("Hello"), size: CGSize(width: 200, height: 100))
        let text = try #require(host.view(withText: "Hello"))
        // body font 13pt: 5 chars × 6.5 = 32.5 → 33 wide, 16 tall
        #expect(text.frame == CGRect(x: 84, y: 42, width: 33, height: 16))
    }

    @Test func vstackStacksWithDefaultSpacing() throws {
        let host = TestHost(
            VStack(alignment: .leading) {
                Text("A")
                Text("BBBB")
            },
            size: CGSize(width: 200, height: 200)
        )
        let a = try #require(host.view(withText: "A"))
        let b = try #require(host.view(withText: "BBBB"))
        #expect(a.frame.minX == b.frame.minX)
        #expect(b.frame.minY == a.frame.maxY + 8)
    }

    @Test func hstackDistributesFlexibleSpace() throws {
        let host = TestHost(
            HStack(spacing: 0) {
                Color.red
                Color.blue.frame(width: 50)
                Color.green
            }.frame(width: 250, height: 10),
            size: CGSize(width: 300, height: 100)
        )
        let colors = host.allViews.filter { if case .color = $0.content { return true }; return false }
        #expect(colors.map(\.frame.width) == [100, 50, 100])
    }

    @Test func spacerPushesContent() throws {
        let host = TestHost(
            HStack {
                Text("L")
                Spacer()
                Text("R")
            }.frame(width: 300),
            size: CGSize(width: 300, height: 100)
        )
        let left = try #require(host.view(withText: "L"))
        let right = try #require(host.view(withText: "R"))
        #expect(left.absoluteFrame.minX == 0)
        #expect(right.absoluteFrame.maxX == 300)
    }

    @Test func paddingAndFrame() throws {
        let host = TestHost(
            Color.red.frame(width: 20, height: 20).padding(10).background(Color.blue),
            size: CGSize(width: 100, height: 100)
        )
        let colors = host.allViews.filter(\.isFill)
        // background first (z-order), 40×40 centered; foreground 20×20 inset by 10.
        #expect(colors[0].frame == CGRect(x: 30, y: 30, width: 40, height: 40))
        #expect(colors[1].frame == CGRect(x: 40, y: 40, width: 20, height: 20))
    }

    @Test func overlayIsAlignedToBase() throws {
        let host = TestHost(
            Color.red.frame(width: 100, height: 50).overlay(alignment: .bottomTrailing) { Text("x") },
            size: CGSize(width: 100, height: 50)
        )
        let x = try #require(host.view(withText: "x"))
        #expect(x.frame.maxX == 100)
        #expect(x.frame.maxY == 50)
    }

    @Test func customLayout() throws {
        struct Diagonal: Layout {
            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                CGSize(width: 10 * CGFloat(subviews.count), height: 10 * CGFloat(subviews.count))
            }
            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                for (index, subview) in subviews.enumerated() {
                    subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * 10, y: bounds.minY + CGFloat(index) * 10), proposal: ProposedViewSize(width: 10, height: 10))
                }
            }
        }
        let host = TestHost(Diagonal { Color.red; Color.green; Color.blue }, size: CGSize(width: 30, height: 30))
        let colors = host.allViews.filter { if case .color = $0.content { return true }; return false }
        #expect(colors.map(\.frame.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)])
    }

    @Test func geometryReaderReceivesSize() throws {
        let host = TestHost(
            GeometryReader { proxy in
                Text("\(Int(proxy.size.width))x\(Int(proxy.size.height))")
            },
            size: CGSize(width: 120, height: 80)
        )
        #expect(host.texts == ["120x80"])
        host.resize(to: CGSize(width: 150, height: 80))
        #expect(host.texts == ["150x80"])
    }

    @Test func flexibleFrameMaxWidthInfinity() throws {
        let host = TestHost(
            Text("hi").frame(maxWidth: .infinity, alignment: .leading).background(Color.red),
            size: CGSize(width: 300, height: 100)
        )
        let fill = host.allViews.first(where: \.isFill)
        let red = try #require(fill)
        #expect(red.frame.width == 300)
        #expect(host.view(withText: "hi")!.frame.minX == 0)
    }
}
