import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Raw input over a view, as the backend sees it: for views SwiftUI's gestures can't serve (a remote desktop's
/// picture needs every button, the wheel and each key's position). Backends wrap it in a typed modifier
/// (SwiftUIGtk's `onGtkInput`); backends without one never call it.
public struct _PlatformInputModifier: PlatformEffectModifier {
    static var hasActions: Bool { true }
    let handler: @MainActor (Any) -> Bool
    static var pathComponent: String { "platformInput" }
    func effect(size: CGSize) -> DisplayEffect { .tapTarget }

    func actions(modifier: Attribute<Self>) -> RenderActions {
        var actions = RenderActions()
        actions.platformInput = { [weak modifier] event in
            guard let modifier else { return false }
            return AnyAttribute.withoutDependencies { modifier.value.handler(event) }
        }
        return actions
    }
}

extension View {
    /// Not Apple API: the backend's raw input events over this view; the handler returns whether it took one.
    public func _onPlatformInput(_ handler: @escaping @MainActor (Any) -> Bool) -> some View {
        modifier(_PlatformInputModifier(handler: handler))
    }
}
