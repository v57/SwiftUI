// Umbrella module: `import SwiftUI2` gives the SwiftUI API plus the backend for the current
// platform. App code should only ever import this module.
@_exported import Foundation
@_exported import SwiftUI2Core
@_exported import Observation
#if canImport(CoreTransferable)
@_exported import CoreTransferable
#endif
#if canImport(UniformTypeIdentifiers)
@_exported import UniformTypeIdentifiers
#endif

#if canImport(AppKit)
// Like `import SwiftUI` on macOS, `import SwiftUI2` also gives access to AppKit.
@_exported import AppKit
@_exported import SwiftUI2AppKit
#endif
#if os(Android)
@_exported import SwiftUI2Android
#endif
#if os(Linux)
@_exported import SwiftUI2Gtk
#endif
#if os(Windows)
@_exported import SwiftUI2WinUI
#endif
#if canImport(SwiftData)
@_exported import SwiftUI2SwiftData
#endif

extension App {
    @MainActor
    public static func main() {
        #if os(Android)
        // The activity owns the main loop: register the scenes and return to the host.
        AndroidAppRunner.register(AppRuntime.prepare(Self.self))
        #elseif os(Windows)
        // The C# host owns the message loop: register the scenes and return to the host.
        WinUIAppRunner.register(AppRuntime.prepare(Self.self))
        #else
        #if canImport(AppKit)
        AppKitAppRunner.install()
        #elseif os(Linux)
        GtkAppRunner.install()
        #endif
        AppRuntime.run(Self.self)
        #endif
    }
}
