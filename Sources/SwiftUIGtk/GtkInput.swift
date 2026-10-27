#if os(Linux)
import Foundation
import CGtk3
import _SwiftUICore

/// One raw GTK input event over a view that takes them (`onGtkInput`): presses and releases of every button, pointer
/// motion (also while a button is held), the wheel, and keys while the view has focus (it gets focus when pressed and
/// loses it when another view is pressed).
public struct GtkInputEvent: Sendable {
    public enum Kind: Sendable {
        /// `button` is GDK's (1 left, 2 middle, 3 right, 8 and 9 back and forward); `clicks` counts quick presses.
        case buttonDown(button: Int, clicks: Int)
        case buttonUp(button: Int)
        case motion
        /// Wheel notches (±1) or a touchpad's smooth deltas (`precise`); positive dy scrolls down.
        case scroll(dx: Double, dy: Double, precise: Bool)
        /// `keyval` as typed (shifted), `unshiftedKeyval` the key's own (level 1) keysym, `keycode` the hardware's.
        case keyDown(keyval: UInt32, unshiftedKeyval: UInt32, keycode: UInt16, text: String)
        case keyUp(keyval: UInt32, unshiftedKeyval: UInt32, keycode: UInt16)
        /// Another view was pressed or the window lost focus: keys still held won't come up here.
        case focusLost
    }

    public var kind: Kind
    /// The pointer in the view's coordinates (points, top-left origin).
    public var location: CGPoint
    /// GDK's modifier mask (`GdkModifierType`: shift 1, caps lock 2, control 4, alt 8, super 0x4000000).
    public var state: UInt32

    public init(kind: Kind, location: CGPoint, state: UInt32) {
        self.kind = kind
        self.location = location
        self.state = state
    }

    public static let shiftMask: UInt32 = GDK_SHIFT_MASK.rawValue
    public static let lockMask: UInt32 = GDK_LOCK_MASK.rawValue
    public static let controlMask: UInt32 = GDK_CONTROL_MASK.rawValue
    public static let altMask: UInt32 = GDK_MOD1_MASK.rawValue
    public static let superMask: UInt32 = GDK_SUPER_MASK.rawValue | GDK_MOD4_MASK.rawValue
}

extension View {
    /// Not Apple API: GTK's raw input over this view (a remote desktop's picture). The handler returns whether it took
    /// the event; the view takes every press inside it.
    public func onGtkInput(_ handler: @escaping @MainActor (GtkInputEvent) -> Bool) -> some View {
        _onPlatformInput { event in (event as? GtkInputEvent).map(handler) ?? false }
    }
}

/// The host's side: which view has the keyboard and the pointer, and click counting.
@MainActor
struct GtkInputRouting {
    weak var focus: GtkNode?
    weak var capture: GtkNode?
    var buttons: Set<guint> = []
    var lastPress: (time: guint32, button: guint, point: CGPoint, clicks: Int)?

    /// Counts presses of one button close in time and place (GTK's default double-click time and distance).
    mutating func clicks(for event: GdkEventButton, at point: CGPoint) -> Int {
        var clicks = 1
        if let last = lastPress, last.button == event.button, event.time &- last.time <= 400,
            abs(last.point.x - point.x) <= 5, abs(last.point.y - point.y) <= 5
        {
            clicks = last.clicks + 1
        }
        lastPress = (event.time, event.button, point, clicks)
        return clicks
    }

    /// The level-1 keysym of a key (`a` for Shift+A, `1` for `!` on a US layout).
    static func unshiftedKeyval(_ event: GdkEventKey) -> UInt32 {
        guard let keymap = gdk_keymap_get_for_display(gdk_display_get_default()) else { return event.keyval }
        var keyval: guint = 0
        guard
            gdk_keymap_translate_keyboard_state(
                keymap, guint(event.hardware_keycode), GdkModifierType(rawValue: 0), gint(event.group), &keyval, nil, nil,
                nil) != 0
        else { return event.keyval }
        return keyval
    }
}
#endif
