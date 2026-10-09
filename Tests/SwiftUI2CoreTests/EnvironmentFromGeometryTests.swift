import Testing
@testable import SwiftUI2Core
import SwiftUI2Headless

@MainActor
struct EnvironmentFromGeometryTests {
    /// Environment values computed from a GeometryReader proxy are only known after layout; the
    /// writing modifier must not read them while the graph is built.
    @Test func environmentValueDerivedFromGeometry() {
        struct V: View {
            var body: some View {
                GeometryReader { proxy in
                    ZStack {
                        Text("Glyph").font(.system(size: proxy.size.width * 0.5))
                    }
                }
                .frame(width: 40, height: 40)
            }
        }
        let host = TestHost(V())
        let text = host.view(withText: "Glyph")
        // Headless metrics: 1.2 × pt line height for 20pt.
        #expect(text?.frame.height == 24)
    }
}
