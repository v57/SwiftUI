import Foundation

/// The element channel for test tools (docs/BACKENDS.md, "Element channel"): with `SWIFTUI_INSPECT=1` in its
/// environment, an app answers `elements` on a local endpoint named after its process with every window's visible
/// elements as JSON, so a tool outside the process (Remote's hosts) can find "Save" without accessibility APIs.
/// Backends own the endpoint and the node walk; this is the shared model and the mapping from rendered content.
public enum _Inspection {
    /// Whether this process should answer (`SWIFTUI_INSPECT` set to anything but empty or 0). Off by default: nothing
    /// is opened unless the person running the app asks for it.
    public static var isEnabled: Bool {
        guard let value = ProcessInfo.processInfo.environment["SWIFTUI_INSPECT"] else { return false }
        return !value.isEmpty && value != "0"
    }

    /// Where a process answers: a Unix socket in the user's runtime directory (Linux), a named pipe's name (Windows).
    public static func endpoint(pid: Int32) -> String {
        #if os(Windows)
        return "swiftui-inspect-\(pid)"
        #else
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            return runtime + "/swiftui-inspect-\(pid)"
        }
        return NSTemporaryDirectory() + "swiftui-inspect-\(getuid())-\(pid)"
        #endif
    }

    /// What a node is to a test tool.
    public enum Decision: Equatable {
        /// Hidden from tools, with everything under it.
        case hidden
        /// Only layout or decoration: its children may be elements.
        case pass
        /// An element; `leaf` ones speak for their children (a button's label isn't listed again).
        case element(role: String, label: String, value: String, leaf: Bool)
    }

    /// The role, label and value of rendered content, as a screen reader would name them: the accessibility label
    /// first, else the text a control shows (`descendantText`, a button's label), its placeholder or its symbol.
    public static func decide(
        _ content: RenderContent, accessibility: AccessibilityProperties?, hasPrimaryAction: Bool,
        descendantText: () -> String
    ) -> Decision {
        if accessibility?.isHidden == true { return .hidden }
        let traits = accessibility?.traits ?? []
        let given = accessibility?.label.flatMap { $0.isEmpty ? nil : $0 }
        let givenValue = accessibility?.value ?? ""
        func label(_ fallback: @autoclosure () -> String) -> String { given ?? fallback() }
        switch content {
        case .text(let text):
            return .element(role: traits.contains(.isHeader) ? "heading" : "text", label: label(text.string), value: givenValue, leaf: true)
        case .button:
            return .element(role: traits.contains(.isLink) ? "link" : "button", label: label(descendantText()), value: givenValue, leaf: true)
        case .toggle(let toggle):
            return .element(role: "toggle", label: label(descendantText()), value: toggle.isMixed ? "mixed" : toggle.isOn ? "on" : "off", leaf: true)
        case .textField(let field):
            return .element(
                role: field.isSecure ? "securefield" : traits.contains(.isSearchField) ? "searchfield" : "textfield",
                label: label(field.placeholder), value: field.isSecure ? "" : field.text, leaf: true)
        case .slider(let slider):
            return .element(role: "slider", label: label(descendantText()), value: String(slider.value), leaf: true)
        case .datePicker(let picker):
            return .element(role: "datepicker", label: label(""), value: ISO8601DateFormatter().string(from: picker.date), leaf: true)
        case .colorWell:
            return .element(role: "colorwell", label: label(""), value: givenValue, leaf: true)
        case .image(let image):
            let name: String
            switch image.source {
            case .system(let symbol): name = symbol
            case .named(let named): name = named
            case .platform: name = ""
            }
            return .element(role: "image", label: label(name), value: givenValue, leaf: true)
        case .scrollView:
            return .element(role: "scrollarea", label: label(""), value: givenValue, leaf: false)
        case .effect(.tapTarget):
            return .element(role: "button", label: label(descendantText()), value: givenValue, leaf: true)
        default:
            // A tap gesture on a group, or accessibility given to a container.
            if hasPrimaryAction || traits.contains(.isButton) {
                return .element(role: traits.contains(.isLink) ? "link" : "button", label: label(descendantText()), value: givenValue, leaf: true)
            }
            if let given {
                let role = traits.contains(.isHeader) ? "heading" : traits.contains(.isImage) ? "image" : "group"
                return .element(role: role, label: given, value: givenValue, leaf: accessibility?.children == .combine)
            }
            return .pass
        }
    }

    /// Whether a control takes input (content without a state of its own always does).
    public static func takesInput(_ content: RenderContent) -> Bool {
        switch content {
        case .button(let button): return button.isEnabled
        case .toggle(let toggle): return toggle.isEnabled
        case .textField(let field): return field.isEnabled
        case .slider(let slider): return slider.isEnabled
        case .datePicker(let picker): return picker.isEnabled
        default: return true
        }
    }

    /// The JSON answer to `elements`: one line.
    public static func encode(_ windows: [_InspectedWindow]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(_InspectedWindows(windows: windows))) ?? Data("{\"windows\":[]}".utf8)
        data.append(0x0A)
        return data
    }
}

/// The answer to `elements`.
public struct _InspectedWindows: Codable, Sendable {
    public var windows: [_InspectedWindow]
}

/// One window: its elements in its own pixels, from the top-left of what shows of it (no invisible borders or
/// shadows), as a screenshot of the window shows them.
public struct _InspectedWindow: Codable, Sendable {
    public var title: String
    /// The native window: an X window id, an HWND.
    public var id: UInt64?
    public var width: Double
    public var height: Double
    /// Pixels per point.
    public var scale: Double
    public var elements: [_InspectedElement]

    public init(title: String, id: UInt64?, width: Double, height: Double, scale: Double, elements: [_InspectedElement]) {
        self.title = title
        self.id = id
        self.width = width
        self.height = height
        self.scale = scale
        self.elements = elements
    }
}

public struct _InspectedElement: Codable, Equatable, Sendable {
    public var role: String
    public var label: String
    public var value: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// How many elements it is inside of.
    public var depth: Int
    public var enabled: Bool

    public init(role: String, label: String, value: String, x: Double, y: Double, width: Double, height: Double, depth: Int, enabled: Bool) {
        self.role = role
        self.label = label
        self.value = value
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.depth = depth
        self.enabled = enabled
    }
}
