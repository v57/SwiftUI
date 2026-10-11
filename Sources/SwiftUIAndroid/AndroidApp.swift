#if os(Android)
import Foundation
import CSwiftUIAndroid
import _SwiftUICore

/// Runs an `App` on Android. The activity owns the main loop: `App.main()` (called by the host
/// through the library's `main`) only registers the scenes; `dev.v57.swiftui.SwiftUIActivity` then
/// creates a host for the scene that opens at launch.
@MainActor
public enum AndroidAppRunner {
    static var scenes: [WindowDescription] = []

    public static func register(_ windows: [WindowDescription]) {
        scenes = windows
        AppRuntime.openWindow = { id, _ in
            AndroidLog.warning("openWindow(id: \(id ?? "nil")) is not supported on Android yet")
        }
        AppRuntime.dismissWindow = { _, _ in }
        if ProcessInfo.processInfo.environment["SWIFTUI_PERF"] != nil || AndroidSystemProperties.get("debug.swiftui.perf") == "1" {
            AndroidPerf.enabled = true
        }
    }

    /// The scene a new activity shows: an index, or the first scene that opens at launch.
    static func scene(_ index: Int32) -> WindowDescription? {
        if index >= 0, Int(index) < scenes.count { return scenes[Int(index)] }
        return scenes.first(where: \.opensAtLaunch) ?? scenes.first
    }
}

enum AndroidSystemProperties {
    static func get(_ name: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 92) // PROP_VALUE_MAX
        let length = __system_property_get(name, &buffer)
        return length > 0 ? String(cString: buffer) : nil
    }
}

// MARK: - Kotlin → Swift (see CSwiftUIAndroid.h)

@MainActor
private func host(_ handle: Int64) -> AndroidHost? {
    guard let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return nil }
    return Unmanaged<AndroidHost>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("swiftui_create_host")
public func swiftui_create_host(_ view: sui_ref?, _ density: Float, _ scene: Int32) -> Int64 {
    nonisolated(unsafe) let view = view
    return MainActor.assumeIsolated {
        guard let view, let description = AndroidAppRunner.scene(scene) else {
            AndroidLog.error("No scene to show (did the library's App.main() run?)")
            return 0
        }
        let host = AndroidHost(view: view, density: CGFloat(density)) { backend in description.makeGraphForValue(backend, nil) }
        return Int64(Int(bitPattern: Unmanaged.passRetained(host).toOpaque()))
    }
}

@_cdecl("swiftui_destroy_host")
public func swiftui_destroy_host(_ handle: Int64) {
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: Int(handle)) else { return }
        let host = Unmanaged<AndroidHost>.fromOpaque(pointer)
        host.takeUnretainedValue().tearDown()
        host.release()
    }
}

@_cdecl("swiftui_set_size")
public func swiftui_set_size(_ handle: Int64, _ width: Float, _ height: Float) {
    MainActor.assumeIsolated {
        host(handle)?.setSize(CGSize(width: CGFloat(width), height: CGFloat(height)))
        AndroidMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui_set_insets")
public func swiftui_set_insets(_ handle: Int64, _ top: Float, _ left: Float, _ bottom: Float, _ right: Float) {
    // The host view lays the content out inside the insets; nothing to do in the graph yet.
}

@_cdecl("swiftui_set_environment")
public func swiftui_set_environment(_ handle: Int64, _ key: Int32, _ value: Int32) {
    MainActor.assumeIsolated { host(handle)?.setEnvironment(key: key, value: value) }
}

@_cdecl("swiftui_event")
public func swiftui_event(_ handle: Int64, _ node: Int32, _ type: Int32, _ a: Double, _ b: Double, _ c: Double, _ text: UnsafePointer<CChar>?) {
    let string = text.map { String(cString: $0) }
    MainActor.assumeIsolated {
        host(handle)?.handle(node: node, type: type, a: a, b: b, c: c, text: string)
        AndroidMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui_frame")
public func swiftui_frame(_ handle: Int64, _ seconds: Double) {
    MainActor.assumeIsolated {
        host(handle)?.frame()
        AndroidMainLoop.serviceTimers()
    }
}

@_cdecl("swiftui_back")
public func swiftui_back(_ handle: Int64) -> Bool {
    MainActor.assumeIsolated { host(handle)?.back() ?? false }
}

@_cdecl("swiftui_timer_fired")
public func swiftui_timer_fired() {
    MainActor.assumeIsolated { AndroidMainLoop.serviceTimers() }
}
#endif
