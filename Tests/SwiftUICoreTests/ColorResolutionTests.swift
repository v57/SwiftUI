import Testing
@testable import _SwiftUICore

@MainActor
struct ColorResolutionTests {
    @Test func accentTintResolvesToTheSystemAccent() {
        var environment = EnvironmentValues()
        environment.tint = .accentColor
        #expect(Color.accentColor.resolve(in: environment) == Color.blue.resolve(in: environment))
        environment.tint = .accentColor.opacity(0.5)
        #expect(Color.accentColor.resolve(in: environment).opacity == Color.blue.resolve(in: environment).opacity * 0.5)
    }

    @Test func explicitTintReplacesTheAccent() {
        var environment = EnvironmentValues()
        environment.tint = .orange
        #expect(Color.accentColor.resolve(in: environment) == Color.orange.resolve(in: environment))
    }
}
