import Observation
import Testing
@testable import _SwiftUICore
import SwiftUIHeadless

@MainActor
struct ModifierObservationTests {
    @Observable final class Model {
        var activation = 0
    }

    struct Watch: ViewModifier {
        let model: Model?
        let action: () -> Void

        func body(content: Content) -> some View {
            content.onChange(of: model?.activation ?? 0) { action() }
        }
    }

    @Test func modifierBodyFollowsObservableReads() {
        let model = Model()
        var fired = 0
        let host = TestHost(Text("x").modifier(Watch(model: model, action: { fired += 1 })))
        host.flush()
        model.activation += 1
        host.flush()
        #expect(fired == 1)
    }
}
