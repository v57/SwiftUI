import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Platform-independent description of what a platform node shows. Backends switch over it.
public enum RenderContent: Equatable {
    case empty
    case text(ResolvedText)
    case color(Color.Resolved)
    case shape(ResolvedShape)
    case image(ResolvedImage)
    /// Container: children are the label.
    case button(ResolvedButton)
    case toggle(ResolvedToggle)
    case textField(ResolvedTextField)
    case slider(ResolvedSlider)
    /// Container: children are the scrollable content.
    case scrollView(ResolvedScrollView)
    /// Container applying a display effect to its children.
    case effect(DisplayEffect)
    case datePicker(ResolvedDatePicker)
    case colorWell(Color.Resolved)
    /// Canvas drawing commands, in the node's local coordinates.
    case drawing([DrawCommand])
    /// An embedded native view (representables).
    case platformView(PlatformViewToken)
}

public struct ResolvedDatePicker: Equatable, Sendable {
    public var date: Date
    public var components: DatePickerComponents
    public var isEnabled: Bool
}

public struct ResolvedShape: Equatable, Sendable {
    public var path: Path
    public var fill: Color.Resolved?
    public var stroke: Color.Resolved?
    public var lineWidth: CGFloat
    /// Gradient paint replacing `fill` / `stroke` color when set.
    public var gradient: ResolvedGradient?
    public var strokeStyle: StrokeStyle?
    public var shadow: ResolvedShadow?
    /// Size the path was built for; backends scale it to the node's current (possibly animating)
    /// frame. Zero means "draw as is".
    public var pathSize: CGSize = .zero
}

public struct ResolvedButton: Equatable, Sendable {
    public var style: ButtonStyleKind
    public var isEnabled: Bool
    public var tint: Color.Resolved?
}

public struct ResolvedToggle: Equatable, Sendable {
    public var isOn: Bool
    public var style: ToggleStyleKind
    public var isEnabled: Bool
}

public struct ResolvedTextField: Equatable, Sendable {
    public var text: String
    public var placeholder: String
    public var isEnabled: Bool
    public var font: Font.Resolved
    public var isSecure = false
    public var isMultiline = false
    public var style: TextFieldStyleKind = .automatic
    /// Requested focus state from `@FocusState` (backends make the field first responder).
    public var wantsFocus = false
    public var color: Color.Resolved = Color.Resolved(red: 0, green: 0, blue: 0)
}

public struct ResolvedSlider: Equatable, Sendable {
    public var value: Double
    public var range: ClosedRange<Double>
    public var isEnabled: Bool
}

public struct ResolvedScrollView: Equatable, Sendable {
    public var axes: Axis.Set
    public var contentSize: CGSize
    public var contentOrigin: CGPoint
    public var showsIndicators: Bool
    /// Programmatic scroll request (ScrollViewReader); applied when `scrollRequestID` changes.
    public var requestedOffset: CGPoint? = nil
    public var scrollRequestID: Int = 0
    public var isScrollEnabled = true
}

public enum DisplayEffect: Equatable, Sendable {
    case opacity(Double)
    case clip(Path)
    case tapTarget
    case transform(offset: CGSize, scale: CGSize, rotationDegrees: Double)
    case shadow(ResolvedShadow)
}

public struct ResolvedShadow: Equatable, Sendable {
    public var color: Color.Resolved
    public var radius: CGFloat
    public var offset: CGSize

    static func interpolate(_ a: ResolvedShadow, _ b: ResolvedShadow, _ t: Double) -> ResolvedShadow {
        ResolvedShadow(color: .interpolate(a.color, b.color, t), radius: lerp(a.radius, b.radius, t),
                       offset: CGSize(width: lerp(a.offset.width, b.offset.width, t), height: lerp(a.offset.height, b.offset.height, t)))
    }
}

/// Event handlers attached to a platform node. Handlers read the latest view value when they fire.
public struct RenderActions {
    public var primary: (@MainActor () -> Void)?
    public var setBool: (@MainActor (Bool) -> Void)?
    public var setText: (@MainActor (String) -> Void)?
    public var setDouble: (@MainActor (Double) -> Void)?
    public var setDate: (@MainActor (Date) -> Void)?
    public var setColor: (@MainActor (Color.Resolved) -> Void)?
    /// Press state for tap targets (custom ButtonStyles).
    public var pressed: (@MainActor (Bool) -> Void)?
    /// Return key in text fields.
    public var submit: (@MainActor () -> Void)?
    public var focusChanged: (@MainActor (Bool) -> Void)?
    public var hover: (@MainActor (Bool) -> Void)?
    /// Raw pointer events in the node's local coordinates (gestures).
    public var pointer: (@MainActor (PointerEvent) -> Void)?
    public var keyboardShortcut: KeyboardShortcut?
    /// Right click / long press (context menus).
    public var secondaryClick: (@MainActor () -> Void)?
    /// Scroll views report their content offset.
    public var scrolled: (@MainActor (CGPoint) -> Void)?
    /// Drop destination: accepted type identifiers (UTType identifiers on Apple platforms).
    public var dropTypes: [String] = []
    /// Drag enters (`true`) / leaves (`false`) the node.
    public var dropTargeted: (@MainActor (Bool) -> Void)?
    /// Drag moved over the node (local coordinates).
    public var dropUpdated: (@MainActor (CGPoint) -> Void)?
    /// Items dropped (platform item providers, e.g. `NSItemProvider`) at a local location.
    /// Returns whether the drop was accepted.
    public var drop: (@MainActor (_ providers: [AnyObject], _ location: CGPoint) -> Bool)?
    /// Drag source: makes the item provider (`NSItemProvider` on Apple platforms) for a drag.
    public var dragItem: (@MainActor () -> AnyObject?)?
    public init() {}
}

public struct PointerEvent: Sendable {
    public enum Phase: Sendable { case began, moved, ended, cancelled }
    public var phase: Phase
    public var location: CGPoint
    public var timestamp: Double
    public init(phase: Phase, location: CGPoint, timestamp: Double) {
        self.phase = phase
        self.location = location
        self.timestamp = timestamp
    }
}

// RenderNode and Renderer live in Renderer.swift.

/// Measurement services a backend provides to layout.
@MainActor
public protocol PlatformServices: AnyObject {
    func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize
    /// Distance from the top of the text to its first baseline.
    func firstBaseline(of text: ResolvedText) -> CGFloat
    func imageSize(_ image: ResolvedImage) -> CGSize
    func controlMetrics(_ control: ControlKind) -> ControlMetrics
    /// Font-dependent vertical spacing of text (nil: plain default spacing).
    func textSpacing(_ font: Font.Resolved) -> TextSpacing?
}

extension PlatformServices {
    public func textSpacing(_ font: Font.Resolved) -> TextSpacing? { nil }
}

public enum ControlKind: Hashable, Sendable {
    case button(ButtonStyleKind)
    case checkbox
    case `switch`
    case textField
    case slider
}

public struct ControlMetrics: Hashable, Sendable {
    /// Insets around a container control's label.
    public var contentInsets: EdgeInsets
    /// Fixed or minimum size of the control chrome.
    public var minSize: CGSize
    /// Ideal width for controls without intrinsic width (text fields, sliders).
    public var idealWidth: CGFloat

    public init(contentInsets: EdgeInsets = EdgeInsets(), minSize: CGSize = .zero, idealWidth: CGFloat = 0) {
        self.contentInsets = contentInsets
        self.minSize = minSize
        self.idealWidth = idealWidth
    }
}

/// A rendering backend: creates/updates platform views for render nodes.
@MainActor
public protocol RenderBackend: PlatformServices {
    /// The view that hosts the root of the tree.
    var rootHandle: AnyObject { get }
    /// Creates a view for a platform node, configured with its current content, frame and actions.
    func makeView(for node: RenderNode) -> AnyObject
    func updateContent(of view: AnyObject, node: RenderNode)
    func setFrame(of view: AnyObject, node: RenderNode)
    /// Replaces the platform children of a container view (z-order: first is bottom-most).
    func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject])
    /// Applies `node.presentation` (transition opacity / transform), relative to the view's frame.
    func setPresentation(of view: AnyObject, node: RenderNode)
    /// Opens a URL with the platform's default handler (`Link`, `openURL`).
    func openURL(_ url: URL)
    /// Shows a native open/save panel; `completion` gets the chosen URLs, or nil when cancelled.
    func presentFileDialog(_ request: FileDialogRequest, completion: @escaping @MainActor ([URL]?) -> Void)
}

extension RenderBackend {
    public func setPresentation(of view: AnyObject, node: RenderNode) {}
    public func openURL(_ url: URL) {}
    public func presentFileDialog(_ request: FileDialogRequest, completion: @escaping @MainActor ([URL]?) -> Void) {
        completion(nil)
    }
}

/// A native file panel request (`fileImporter` / `fileExporter`).
public struct FileDialogRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case open, save }
    public var kind: Kind
    /// Allowed content type identifiers (empty: anything).
    public var contentTypes: [String]
    public var allowsMultipleSelection = false
    public var canChooseDirectories = false
    public var defaultFilename: String?

    public init(kind: Kind, contentTypes: [String], allowsMultipleSelection: Bool = false, canChooseDirectories: Bool = false, defaultFilename: String? = nil) {
        self.kind = kind
        self.contentTypes = contentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.canChooseDirectories = canChooseDirectories
        self.defaultFilename = defaultFilename
    }
}
