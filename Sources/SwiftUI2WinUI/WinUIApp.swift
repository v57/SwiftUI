#if os(Windows)
import Foundation
import CSwiftUI2WinUI
import SwiftUI2Core

/// Runs an `App` on Windows. The C# host owns the process and the message loop: it loads the app
/// DLL and runs its `main` (`swiftui2_run_main`), where `App.main()` registers the scenes and asks
/// the host to open the launch window. Each window's `HostView` then creates a `WinUIHost`.
@MainActor
public enum WinUIAppRunner {
    static var scenes: [WindowDescription] = []

    /// Open windows: the scene index and presented value of each host.
    private struct OpenWindow {
        weak var host: WinUIHost?
        var scene: Int
        var value: AnyHashable?
    }

    private static var windows: [OpenWindow] = []
    /// Values of windows being opened (`openWindow(value:)`), by the id passed to the host.
    private static var pendingValues: [Int64: AnyHashable] = [:]
    private static var nextValueID: Int64 = 1

    public static func register(_ descriptions: [WindowDescription]) {
        scenes = descriptions
        AppRuntime.openWindow = { id, value in open(id: id, value: value) }
        AppRuntime.dismissWindow = { id, value in dismiss(id: id, value: value) }
        if ProcessInfo.processInfo.environment["SWIFTUI2_PERF"] != nil {
            WinUIPerf.enabled = true
        }
        WinUIText.install()
        if let index = descriptions.firstIndex(where: \.opensAtLaunch) ?? (descriptions.isEmpty ? nil : 0) {
            openScene(index, value: nil)
        }
    }

    static func openScene(_ index: Int, value: AnyHashable?) {
        let scene = scenes[index]
        var valueID: Int64 = -1
        if let value {
            valueID = nextValueID
            nextValueID += 1
            pendingValues[valueID] = value
        }
        let size = scene.defaultSize ?? CGSize(width: -1, height: -1)
        sui_open_window(Int32(index), valueID, scene.title, Float(size.width), Float(size.height))
    }

    private static func sceneIndex(id: String?, value: AnyHashable?) -> Int? {
        if let id { return scenes.firstIndex { $0.id == id } }
        if let value {
            return scenes.firstIndex { scene in scene.valueType.map { type(of: value.base) == $0 } ?? false }
        }
        return scenes.firstIndex(where: \.opensAtLaunch)
    }

    static func open(id: String?, value: AnyHashable?) {
        guard let index = sceneIndex(id: id, value: value) else {
            WinUILog.warning("openWindow: no scene for id \(id ?? "nil") / value \(value.map { "\($0)" } ?? "nil")")
            return
        }
        windows.removeAll { $0.host == nil }
        // Single windows (`Window`) and windows already presenting the value come to the front.
        if let existing = windows.first(where: { $0.scene == index && (scenes[index].isSingle || (value != nil && $0.value == value)) }),
           let host = existing.host {
            _ = WinUIPlatform.call(host.view, .activate, nil)
            return
        }
        openScene(index, value: value)
    }

    static func dismiss(id: String?, value: AnyHashable?) {
        windows.removeAll { $0.host == nil }
        guard let index = sceneIndex(id: id, value: value) else { return }
        for window in windows where window.scene == index && (value == nil || window.value == value) {
            if let host = window.host { sui_close_window(host.view) }
        }
    }

    static func makeHost(view: sui_ref, scene index: Int32, value valueID: Int64) -> WinUIHost? {
        let index = Int(index)
        guard index >= 0, index < scenes.count else {
            WinUILog.error("No scene \(index) to show (did the app's App.main() run?)")
            return nil
        }
        let value = pendingValues.removeValue(forKey: valueID)
        let description = scenes[index]
        let host = WinUIHost(view: view) { backend in description.makeGraphForValue(backend, value) }
        windows.append(OpenWindow(host: host, scene: index, value: value))
        return host
    }
}

// MARK: - C# → Swift (exported from the app DLL, see CSwiftUI2WinUI/bridge.c)

@MainActor
private func host(_ handle: Int64) -> WinUIHost? {
    guard let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return nil }
    return Unmanaged<WinUIHost>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("swiftui2_create_host")
public func swiftui2_create_host(_ view: sui_ref?, _ scene: Int32, _ value: Int64) -> Int64 {
    nonisolated(unsafe) let view = view
    return MainActor.assumeIsolated {
        guard let view, let host = WinUIAppRunner.makeHost(view: view, scene: scene, value: value) else { return 0 }
        return Int64(Int(bitPattern: Unmanaged.passRetained(host).toOpaque()))
    }
}

/// The window closed: tears the graph down and releases the host.
@_cdecl("swiftui2_destroy_host")
public func swiftui2_destroy_host(_ handle: Int64) {
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return }
        let host = Unmanaged<WinUIHost>.fromOpaque(pointer)
        host.takeUnretainedValue().tearDown()
        host.release()
        WinUIMainLoop.serviceTimers()
    }
}

/// The content size (epx) and the rasterization scale (physical pixels per epx).
@_cdecl("swiftui2_set_size")
public func swiftui2_set_size(_ handle: Int64, _ width: Float, _ height: Float, _ scale: Float) {
    MainActor.assumeIsolated {
        host(handle)?.setSize(CGSize(width: CGFloat(width), height: CGFloat(height)), scale: CGFloat(max(scale, 0.1)))
        WinUIMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui2_set_environment")
public func swiftui2_set_environment(_ handle: Int64, _ key: Int32, _ value: Int32) {
    MainActor.assumeIsolated {
        host(handle)?.setEnvironment(key: key, value: value)
        WinUIMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui2_event")
public func swiftui2_event(_ handle: Int64, _ node: Int32, _ type: Int32, _ a: Double, _ b: Double, _ c: Double, _ text: UnsafePointer<CChar>?) {
    let string = text.map { String(cString: $0) }
    MainActor.assumeIsolated {
        host(handle)?.handle(node: node, type: type, a: a, b: b, c: c, text: string)
        WinUIMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui2_frame")
public func swiftui2_frame(_ handle: Int64, _ seconds: Double) {
    MainActor.assumeIsolated {
        host(handle)?.frame()
        WinUIMainLoop.serviceTimers()
    }
}

/// Escape or the title bar's Back button. Returns whether something was dismissed or popped.
@_cdecl("swiftui2_back")
public func swiftui2_back(_ handle: Int64) -> Bool {
    MainActor.assumeIsolated {
        let handled = host(handle)?.back() ?? false
        WinUIMainLoop.serviceTimers()
        return handled
    }
}

/// A key event in the window: `code` is a Unicode scalar or a WinUIKeys code, `modifiers` the
/// host's bits, `phase` 0 down / 1 repeat / 2 up. Returns whether SwiftUI handled it.
@_cdecl("swiftui2_key")
public func swiftui2_key(_ handle: Int64, _ code: Int32, _ characters: UnsafePointer<CChar>?, _ modifiers: Int32, _ phase: Int32) -> Bool {
    let string = characters.map { String(cString: $0) } ?? ""
    return MainActor.assumeIsolated {
        let phases: KeyPress.Phases = phase == 2 ? .up : phase == 1 ? .repeat : .down
        let handled = host(handle)?.key(code: code, characters: string, modifiers: modifiers, phase: phases) ?? false
        WinUIMainLoop.serviceTimers()
        return handled
    }
}

/// Main-queue work ran or a run loop timer is due.
@_cdecl("swiftui2_timer_fired")
public func swiftui2_timer_fired() {
    MainActor.assumeIsolated { WinUIMainLoop.serviceTimers() }
}
#endif
