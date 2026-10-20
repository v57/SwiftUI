import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Window configuration (preference to the hosting window)

public enum WindowInteractionBehavior: Hashable, Sendable { case automatic, enabled, disabled }
public enum WindowToolbarFullScreenVisibility: Hashable, Sendable { case automatic, visible, onHover }

/// Notified while the user resizes the window (`onInteractiveResizeChange`).
@MainActor
public final class WindowResizeObserver {
    let action: @MainActor (Bool) -> Void
    init(action: @escaping @MainActor (Bool) -> Void) { self.action = action }
    public func notify(_ isResizing: Bool) { action(isResizing) }
}

/// Window behavior requested by the views of a window (the innermost setting wins).
public struct WindowConfiguration: Equatable, @unchecked Sendable {
    public var resizeBehavior = WindowInteractionBehavior.automatic
    public var minimizeBehavior = WindowInteractionBehavior.automatic
    public var dismissBehavior = WindowInteractionBehavior.automatic
    public var fullScreenBehavior = WindowInteractionBehavior.automatic
    public var toolbarFullScreenVisibility = WindowToolbarFullScreenVisibility.automatic
    public var resizeAnchor: UnitPoint?
    /// `navigationDocument`: the window's represented file (proxy icon, title menu).
    public var representedURL: URL?
    /// `containerBackground(_:for: .window)`.
    public var background: Color?
    public var isToolbarHidden: Bool?
    public var isToolbarBackgroundHidden: Bool?
    public var toolbarColorScheme: ColorScheme?
    /// `preferredColorScheme`: the window's appearance (nil: the system's).
    public var preferredColorScheme: ColorScheme?
    public var allowsActivationEvents: Bool?
    public var resizeObservers: [WindowResizeObserver] = []
    /// `dismissalConfirmationDialog` in a window: closing asks first.
    public var closeConfirmation: (@MainActor () -> Void)?

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resizeBehavior == rhs.resizeBehavior && lhs.minimizeBehavior == rhs.minimizeBehavior && lhs.dismissBehavior == rhs.dismissBehavior
            && lhs.fullScreenBehavior == rhs.fullScreenBehavior && lhs.toolbarFullScreenVisibility == rhs.toolbarFullScreenVisibility
            && lhs.resizeAnchor == rhs.resizeAnchor && lhs.representedURL == rhs.representedURL && lhs.background == rhs.background
            && lhs.isToolbarHidden == rhs.isToolbarHidden && lhs.isToolbarBackgroundHidden == rhs.isToolbarBackgroundHidden
            && lhs.toolbarColorScheme == rhs.toolbarColorScheme && lhs.allowsActivationEvents == rhs.allowsActivationEvents
            && lhs.preferredColorScheme == rhs.preferredColorScheme
            && lhs.resizeObservers.map(ObjectIdentifier.init) == rhs.resizeObservers.map(ObjectIdentifier.init)
            && (lhs.closeConfirmation == nil) == (rhs.closeConfirmation == nil)
    }

    /// `next` (a later / inner view) overrides what it sets.
    mutating func merge(_ next: WindowConfiguration) {
        if next.resizeBehavior != .automatic { resizeBehavior = next.resizeBehavior }
        if next.minimizeBehavior != .automatic { minimizeBehavior = next.minimizeBehavior }
        if next.dismissBehavior != .automatic { dismissBehavior = next.dismissBehavior }
        if next.fullScreenBehavior != .automatic { fullScreenBehavior = next.fullScreenBehavior }
        if next.toolbarFullScreenVisibility != .automatic { toolbarFullScreenVisibility = next.toolbarFullScreenVisibility }
        resizeAnchor = next.resizeAnchor ?? resizeAnchor
        representedURL = next.representedURL ?? representedURL
        background = next.background ?? background
        isToolbarHidden = next.isToolbarHidden ?? isToolbarHidden
        isToolbarBackgroundHidden = next.isToolbarBackgroundHidden ?? isToolbarBackgroundHidden
        toolbarColorScheme = next.toolbarColorScheme ?? toolbarColorScheme
        preferredColorScheme = next.preferredColorScheme ?? preferredColorScheme
        allowsActivationEvents = next.allowsActivationEvents ?? allowsActivationEvents
        resizeObservers += next.resizeObservers
        closeConfirmation = next.closeConfirmation ?? closeConfirmation
    }
}

public struct WindowConfigurationKey: PreferenceKey {
    public static var defaultValue: WindowConfiguration { WindowConfiguration() }
    public static func reduce(value: inout WindowConfiguration, nextValue: () -> WindowConfiguration) { value.merge(nextValue()) }
}

extension View {
    /// Sets window behavior unless a view inside already chose it (inner settings win).
    func _windowConfiguration(_ edit: @escaping (inout WindowConfiguration) -> Void) -> some View {
        transformPreference(WindowConfigurationKey.self) { value in
            var outer = WindowConfiguration()
            edit(&outer)
            outer.merge(value)
            value = outer
        }
    }

    public func windowResizeBehavior(_ behavior: WindowInteractionBehavior) -> some View { _windowConfiguration { $0.resizeBehavior = behavior } }
    public func windowMinimizeBehavior(_ behavior: WindowInteractionBehavior) -> some View { _windowConfiguration { $0.minimizeBehavior = behavior } }
    public func windowDismissBehavior(_ behavior: WindowInteractionBehavior) -> some View { _windowConfiguration { $0.dismissBehavior = behavior } }
    public func windowFullScreenBehavior(_ behavior: WindowInteractionBehavior) -> some View { _windowConfiguration { $0.fullScreenBehavior = behavior } }
    public func windowToolbarFullScreenVisibility(_ visibility: WindowToolbarFullScreenVisibility) -> some View {
        _windowConfiguration { $0.toolbarFullScreenVisibility = visibility }
    }
    /// The point that stays fixed when the window resizes to fit its content.
    public func windowResizeAnchor(_ anchor: UnitPoint?) -> some View { _windowConfiguration { $0.resizeAnchor = anchor } }

    /// The window represents this file (proxy icon and path menu in the title).
    public func navigationDocument(_ url: URL) -> some View { _windowConfiguration { $0.representedURL = url } }
    public func navigationDocument<D>(_ document: D) -> some View { self }

    /// Clicks in an inactive window also act on the view (click-through).
    public func allowsWindowActivationEvents(_ value: Bool? = true) -> some View { _windowConfiguration { $0.allowsActivationEvents = value } }

    public func onInteractiveResizeChange(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        modifier(_InteractiveResizeModifier(action: action))
    }

    // Toolbars

    /// Removes a toolbar item the system adds by default.
    public func toolbar(removing defaultItemKind: ToolbarDefaultItemKind?) -> some View {
        transformPreference(NavigationChromeKey.self) { chrome in
            if defaultItemKind == .sidebarToggle { chrome.removesSidebarToggle = true }
            if defaultItemKind == .title { chrome.removesTitle = true }
        }
    }

    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { if visibility != .automatic { $0.isToolbarHidden = visibility == .hidden } }
    }
    public func toolbarVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { if visibility != .automatic { $0.isToolbarHidden = visibility == .hidden } }
    }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { if visibility != .automatic { $0.isToolbarBackgroundHidden = visibility == .hidden } }
    }
    public func toolbarBackgroundVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { if visibility != .automatic { $0.isToolbarBackgroundHidden = visibility == .hidden } }
    }
    /// A toolbar background style; on macOS the window toolbar's material is shown or hidden.
    public func toolbarBackground<S: ShapeStyle>(_ style: S, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { $0.isToolbarBackgroundHidden = false }
    }
    public func toolbarColorScheme(_ colorScheme: ColorScheme?, for bars: ToolbarPlacement...) -> some View {
        _windowConfiguration { $0.toolbarColorScheme = colorScheme }
    }
}

struct _InteractiveResizeModifier: ViewModifier {
    let action: @MainActor (Bool) -> Void
    @State private var box = _ResizeObserverBox()

    func body(content: Content) -> some View {
        box.action = action
        let observer = box.observer
        return content._windowConfiguration { $0.resizeObservers.append(observer) }
    }
}

@MainActor
final class _ResizeObserverBox {
    var action: (@MainActor (Bool) -> Void)?
    lazy var observer = WindowResizeObserver { [weak self] in self?.action?($0) }
}

// MARK: - Container backgrounds

public struct ContainerBackgroundPlacement: Hashable, Sendable {
    let id: Int
    public static let window = ContainerBackgroundPlacement(id: 0)
    public static let navigation = ContainerBackgroundPlacement(id: 1)
    public static let navigationSplitView = ContainerBackgroundPlacement(id: 2)
    public static let tabView = ContainerBackgroundPlacement(id: 3)
}

struct NavigationContainerBackgroundKey: EnvironmentKey { static let defaultValue: AnyShapeStyle? = nil }

extension EnvironmentValues {
    var navigationContainerBackground: AnyShapeStyle? {
        get { self[NavigationContainerBackgroundKey.self] }
        set { self[NavigationContainerBackgroundKey.self] = newValue }
    }
}

extension View {
    /// `.window`: the window's background; `.navigation`: behind navigation stack levels.
    public func containerBackground<S: ShapeStyle>(_ style: S, for container: ContainerBackgroundPlacement) -> some View {
        modifier(_ContainerBackgroundModifier(style: AnyShapeStyle(style), placement: container))
    }

    public func containerBackground<V: View>(for container: ContainerBackgroundPlacement, alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        background(alignment: alignment, content: content)
    }
}

struct _ContainerBackgroundModifier: ViewModifier {
    let style: AnyShapeStyle
    let placement: ContainerBackgroundPlacement
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        let style = self.style
        if placement == .window {
            let color = Color(style._resolveColor(in: environment))
            content._windowConfiguration { $0.background = color }
        } else {
            content
                .background(Rectangle().fill(style))
                .environment(\.navigationContainerBackground, style)
        }
    }
}

// MARK: - Scene padding

public struct ScenePadding: Hashable, Sendable {
    public static let minimum = ScenePadding()
    public static let navigationBar = ScenePadding()
}

extension View {
    /// The platform's default spacing around a scene's content (20pt on macOS).
    public func scenePadding(_ edges: Edge.Set = .all) -> some View { padding(edges, 20) }
    public func scenePadding(_ padding: ScenePadding, edges: Edge.Set = .all) -> some View { self.padding(edges, 20) }
}

/// Toolbar items the system provides (`toolbar(removing:)`).
public struct ToolbarDefaultItemKind: Hashable, Sendable {
    let value: Int
    public static let sidebarToggle = ToolbarDefaultItemKind(value: 0)
    public static let title = ToolbarDefaultItemKind(value: 1)
    public static let search = ToolbarDefaultItemKind(value: 2)
}

// MARK: - Title bar area

/// The window's title bar where content runs up into it: its height, and how far the window's own controls reach in
/// from each edge (on Windows the menu bar at the leading end, the minimize, maximize and close buttons at the
/// trailing one). A bar drawn in the title bar (`toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`) keeps
/// clear of them. A v57/SwiftUI addition: nil where the system draws the title bar around the content (the Mac, whose
/// traffic lights have a fixed place).
public struct WindowTitleBarArea: Equatable, Sendable {
    public var height: CGFloat
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(height: CGFloat, leading: CGFloat, trailing: CGFloat) {
        self.height = height
        self.leading = leading
        self.trailing = trailing
    }
}

private struct WindowTitleBarAreaKey: EnvironmentKey {
    static let defaultValue: WindowTitleBarArea? = nil
}

extension EnvironmentValues {
    /// Where the window's title bar is, when the content runs up into it (see `WindowTitleBarArea`).
    public var windowTitleBarArea: WindowTitleBarArea? {
        get { self[WindowTitleBarAreaKey.self] }
        set { self[WindowTitleBarAreaKey.self] = newValue }
    }
}
