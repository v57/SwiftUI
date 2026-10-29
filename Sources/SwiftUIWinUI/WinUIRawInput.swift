#if os(Windows)
import Foundation
import _SwiftUICore

/// One raw input event over a view that takes them (`onWinUIInput`): presses and releases of every button, pointer
/// motion (also while a button is held), the wheel, and keys and typed characters while the view has focus (it gets
/// focus when pressed and loses it when another view is pressed or the window deactivates).
public struct WinUIInputEvent: Sendable {
    public enum Kind: Sendable {
        /// `button` uses GDK's numbers, as `GtkInputEvent` (1 left, 2 middle, 3 right, 8 and 9 back and forward);
        /// `clicks` counts quick presses.
        case buttonDown(button: Int, clicks: Int)
        case buttonUp(button: Int)
        case motion
        /// Wheel notches (±1) or a precision touchpad's smaller steps (`precise`); positive dy scrolls down.
        case scroll(dx: Double, dy: Double, precise: Bool)
        /// A Windows virtual key (`VK_*`); `extended` tells the right-hand Ctrl and Alt and the keypad's Enter apart.
        case keyDown(virtualKey: Int32, extended: Bool, isRepeat: Bool)
        case keyUp(virtualKey: Int32, extended: Bool)
        /// Text a key press typed (after its key down), an IME's result or a character with no key.
        case character(String)
        /// Another view was pressed or the window deactivated: keys still held won't come up here.
        case focusLost
    }

    public var kind: Kind
    /// The pointer in the view's coordinates (points, top-left origin); zero for keys.
    public var location: CGPoint
    public var modifiers: Modifiers

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let alt = Modifiers(rawValue: 4)
        public static let windows = Modifiers(rawValue: 8)
    }

    public init(kind: Kind, location: CGPoint, modifiers: Modifiers) {
        self.kind = kind
        self.location = location
        self.modifiers = modifiers
    }

    /// The host's description ("down 1 2", "up 1", "move", "wheel 0 1 0", "key 65 0 0", "char é", "focuslost").
    init?(_ event: String, location: CGPoint, modifiers: Int32) {
        let parts = event.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""
        let numbers = rest.split(separator: " ").compactMap { Double($0) }
        func number(_ index: Int) -> Double { index < numbers.count ? numbers[index] : 0 }
        let kind: Kind
        switch name {
        case "down": kind = .buttonDown(button: Int(number(0)), clicks: max(1, Int(number(1))))
        case "up": kind = .buttonUp(button: Int(number(0)))
        case "move": kind = .motion
        case "wheel": kind = .scroll(dx: number(0), dy: number(1), precise: number(2) != 0)
        case "key":
            let phase = Int(number(2))
            kind = phase == 2
                ? .keyUp(virtualKey: Int32(number(0)), extended: number(1) != 0)
                : .keyDown(virtualKey: Int32(number(0)), extended: number(1) != 0, isRepeat: phase == 1)
        case "char": kind = .character(rest)
        case "focuslost": kind = .focusLost
        default: return nil
        }
        self.init(kind: kind, location: location, modifiers: Modifiers(rawValue: modifiers))
    }
}

extension View {
    /// Not Apple API: WinUI's raw input over this view (a remote desktop's picture). The handler returns whether it
    /// took the event; the view takes every press inside it.
    public func onWinUIInput(_ handler: @escaping @MainActor (WinUIInputEvent) -> Bool) -> some View {
        _onPlatformInput { event in (event as? WinUIInputEvent).map(handler) ?? false }
    }
}

extension WinUIHost {
    /// From the host (`swiftui_raw_input`): returns whether the view took the event.
    func rawInput(node id: Int32, event: String, x: Double, y: Double, modifiers: Int32) -> Bool {
        guard let node = backend.node(for: id), let handler = node.actions.platformInput,
            let input = WinUIInputEvent(event, location: CGPoint(x: x, y: y), modifiers: modifiers)
        else { return false }
        let handled = handler(input)
        flush()
        return handled
    }
}
#endif
