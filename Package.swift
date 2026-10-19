// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// Layering (see ARCHITECTURE.md):
//
//   SwiftUIGraph      dependency engine (attributes, subgraphs, invalidation). No UI knowledge.
//   _SwiftUICore       the SwiftUI API surface + view graph + layout + render tree. Platform independent.
//   SwiftUIHeadless   deterministic in-memory backend used by tests and parity runs.
//   SwiftUIAppKit     macOS backend (NSView based).
//   SwiftUI           umbrella module apps import; re-exports Core + the platform backend.
//
//   SwiftUIGtk        Linux backend (GTK 3: cairo/Pango drawing, native text entry).
//   SwiftUIAndroid    Android backend (Swift renderer + Kotlin host).
//   SwiftUIWinUI      Windows backend (Swift renderer + C# WinUI 3 host, see Windows/).

let nonApple: [Platform] = [.android, .linux, .windows]

/// Set when cross-compiling from macOS (`Android/scripts/swift-android` does): a manifest can't see the
/// destination platform, and the stand-ins below must exist then. The AppKit tests are left out.
let crossCompiling = Context.environment["SWIFTUI_CROSS_COMPILE"] != nil

/// Stand-ins for Apple-only modules (UniformTypeIdentifiers, CoreTransferable, Combine), so unchanged
/// `import Combine` / `import UniformTypeIdentifiers` code compiles on Linux, Windows and Android. They
/// only exist when building for those platforms: built for macOS, a module named like an SDK one shadows
/// it for every module of the build (SwiftPM searches its own modules first).
#if os(Linux) || os(Windows)
let standIns = true
#else
let standIns = crossCompiling
#endif

/// Dependencies on the stand-ins (none when they don't exist).
func standIns(_ names: String...) -> [Target.Dependency] {
    standIns ? names.map { .target(name: $0, condition: .when(platforms: nonApple)) } : []
}

let package = Package(
    name: "SwiftUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        .library(name: "_SwiftUICore", targets: ["_SwiftUICore"]),
        .library(name: "SwiftUICharts", targets: ["SwiftUICharts"]),
        .library(name: "SwiftUIHeadless", targets: ["SwiftUIHeadless"]),
        .executable(name: "Demo", targets: ["Demo"]),
        .executable(name: "ReferenceApp2", targets: ["ReferenceApp2"]),
    ],
    dependencies: [
        // Macros (@Entry, #Preview).
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(name: "SwiftUIGraph"),
        .macro(
            name: "SwiftUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        // Foundation/CoreGraphics types missing from swift-corelibs-foundation (empty on Apple).
        .target(
            name: "SwiftUIPortability", dependencies: standIns("CoreGraphics", "CoreTransferable", "UniformTypeIdentifiers"),
            linkerSettings: [.linkedLibrary("shell32", .when(platforms: [.windows]))]),
        .target(
            name: "_SwiftUICore",
            dependencies: [
                "SwiftUIGraph", "SwiftUIMacros",
                .target(name: "SwiftUIPortability", condition: .when(platforms: nonApple)),
            ] + standIns("UniformTypeIdentifiers", "Combine")
        ),
        .target(name: "SwiftUIHeadless", dependencies: ["_SwiftUICore"]),
        // MemberImportVisibility keeps Apple's SwiftUICore extensions (which leak in through AppKit) out of
        // this module, so names shared with Apple's API such as AttributeScopes.SwiftUIAttributes stay unambiguous.
        .target(
            name: "SwiftUIAppKit", dependencies: ["_SwiftUICore"],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        // Android backend: Swift renderer + JNI glue; the Kotlin host lives in Android/.
        .target(
            name: "CSwiftUIAndroid",
            linkerSettings: [.linkedLibrary("android", .when(platforms: [.android])), .linkedLibrary("log", .when(platforms: [.android]))]
        ),
        .target(name: "SwiftUIAndroid", dependencies: ["_SwiftUICore", "CSwiftUIAndroid"]),
        // Windows backend: Swift renderer + C exports; the C# WinUI 3 host lives in Windows/.
        .target(name: "CSwiftUIWinUI"),
        .target(name: "SwiftUIWinUI", dependencies: ["_SwiftUICore", "CSwiftUIWinUI"]),
        // GTK 3 backend (Linux). Its sources are Linux-only; CGtk3 is added below when building on Linux.
        .target(name: "SwiftUIGtk", dependencies: ["_SwiftUICore"]),
        // A Swift Charts subset (import SwiftUICharts instead of Charts).
        .target(name: "SwiftUICharts", dependencies: ["_SwiftUICore"]),
        // SwiftData's SwiftUI integration (@Query, .modelContainer) on Apple platforms.
        .target(name: "SwiftUISwiftData", dependencies: ["_SwiftUICore"] + standIns("SwiftData")),
        .target(
            name: "SwiftUI",
            dependencies: [
                "_SwiftUICore",
                .target(name: "SwiftUIAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "SwiftUIAndroid", condition: .when(platforms: [.android])),
                .target(name: "SwiftUIGtk", condition: .when(platforms: [.linux])),
                .target(name: "SwiftUIWinUI", condition: .when(platforms: [.windows])),
                .target(name: "SwiftUISwiftData", condition: .when(platforms: [.macOS, .iOS] + (standIns ? nonApple : []))),
            ]
        ),

        // Parity: the same scenario sources (Parity/Scenarios, symlinked) are compiled against
        // SwiftUI here and against Apple's SwiftUI in AppleSwiftUI/ (the recorder of the golden data).
        .target(
            name: "ParityScenarios",
            dependencies: ["SwiftUI", "SwiftUIHeadless"]
        ),

        // The reference app (Sources/ReferenceApp, the behavioural spec written against Apple's
        // SwiftUI and run on it from AppleSwiftUI/) compiled against SwiftUI.
        .executableTarget(name: "ReferenceApp2", dependencies: ["SwiftUI"]),
        // Small app running on SwiftUI + AppKit backend.
        .executableTarget(name: "Demo", dependencies: ["SwiftUI"]),

        .testTarget(name: "SwiftUIGraphTests", dependencies: ["SwiftUIGraph"]),
        .testTarget(name: "SwiftUICoreTests", dependencies: ["_SwiftUICore", "SwiftUIHeadless"]),
        .testTarget(
            name: "ParityTests",
            dependencies: ["ParityScenarios", "SwiftUIHeadless"],
            resources: [.copy("Golden")]
        ),
    ]
)

if standIns {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-toolchain-sqlite", from: "1.0.0"),
    ]
    // Stand-ins for Apple frameworks that libraries and apps import directly (not through SwiftUI): depend on
    // these products off Apple platforms and `import CryptoKit` / `import SQLite3` / `import os` build unchanged.
    package.products += [
        .library(name: "CryptoKit", targets: ["CryptoKit"]),
        .library(name: "SQLite3", targets: ["SQLite3"]),
        .library(name: "os", targets: ["os"]),
        .library(name: "Network", targets: ["Network"]),
        .library(name: "SwiftData", targets: ["SwiftData"]),
    ]
    package.targets += [
        // CryptoKit: swift-crypto, plus SecureEnclave keys sealed to the device's user (DPAPI on Windows).
        .target(
            name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            linkerSettings: [.linkedLibrary("crypt32", .when(platforms: [.windows]))]),
        // SQLite3: the toolchain's SQLite.
        .target(name: "SQLite3", dependencies: [.product(name: "SwiftToolchainCSQLite", package: "swift-toolchain-sqlite")]),
        // os: Logger, os_log, signposts (dropped) and OSAllocatedUnfairLock.
        .target(name: "os"),
        // SwiftData: @Model, containers and contexts over a JSON file store (SwiftUISwiftData adds @Query).
        .target(name: "SwiftData", dependencies: ["SwiftUIMacros"]),
        // Network: NWConnection (TCP, TLS through SChannel on Windows, connected UDP) and NWListener on sockets.
        .target(
            name: "CNetworkSupport",
            linkerSettings: [
                .linkedLibrary("ws2_32", .when(platforms: [.windows])), .linkedLibrary("secur32", .when(platforms: [.windows])),
                .linkedLibrary("crypt32", .when(platforms: [.windows])),
            ]),
        .target(name: "Network", dependencies: ["CNetworkSupport"]),
        // CoreGraphics: geometry, colors, paths, bitmap images and a software-drawn bitmap context.
        .target(name: "CoreGraphics"),
        .target(name: "UniformTypeIdentifiers"),
        // CoreTransferable: Transferable and its representations.
        .target(name: "CoreTransferable", dependencies: ["UniformTypeIdentifiers"]),
        // Combine: OpenCombine 0.14.0 (MIT, Sources/Combine/LICENSE-OpenCombine.txt) vendored as
        // one module named Combine, with its Apple spellings always on (DispatchQueue/RunLoop as
        // schedulers, Timer.publish, NotificationCenter.publisher, URLSession publishers).
        // No `Darwin` stand-in: a module with that name flips `canImport(Darwin)` for every
        // package in the build (swift-crypto, NIO, ...) and breaks their platform checks.
        .target(name: "COpenCombineHelpers"),
        .target(name: "Combine", dependencies: ["COpenCombineHelpers"], exclude: ["LICENSE-OpenCombine.txt"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CompatTests", dependencies: ["UniformTypeIdentifiers", "Combine", "CryptoKit", "SQLite3", "os", "Network", "SwiftData"]),
    ]
}

#if os(Linux)
// Native Linux build (GTK backend): the other platforms' backends are left out.
let excluded: Set<String> = ["SwiftUIAppKit", "CSwiftUIAndroid", "SwiftUIAndroid"]
package.targets.removeAll { excluded.contains($0.name) }
package.products.removeAll { excluded.contains($0.name) }
for target in package.targets where target.name == "SwiftUI" {
    target.dependencies = ["_SwiftUICore", "SwiftUIGtk", "SwiftUISwiftData"]
}
// GTK 3 headers and libraries (`apt install libgtk-3-dev`). Declared only here: elsewhere SwiftPM would
// look for gtk+-3.0 with pkg-config and warn in every package that depends on SwiftUI.
package.targets += [.systemLibrary(name: "CGtk3", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])])]
for target in package.targets where target.name == "SwiftUIGtk" {
    target.dependencies += ["CGtk3"]
}
// GTK smoke-test app (the Android Gallery's sources).
package.targets += [.executableTarget(name: "GalleryGtk", dependencies: ["SwiftUI"])]
package.products += [.executable(name: "GalleryGtk", targets: ["GalleryGtk"])]
#elseif os(Windows)
// Native Windows build (WinUI backend): executables and the other platforms' backends are left out.
let excluded: Set<String> = ["ReferenceApp2", "Demo", "SwiftUIAppKit", "CSwiftUIAndroid", "SwiftUIAndroid",
                             "SwiftUIGtk"]
package.targets.removeAll { excluded.contains($0.name) }
package.products.removeAll { excluded.contains($0.name) }
for target in package.targets where target.name == "SwiftUI" {
    target.dependencies = ["_SwiftUICore", "SwiftUIWinUI", "SwiftUISwiftData"]
}
// Windows apps are DLLs the C# host loads (Windows/scripts/build-app.ps1); the DLL's `main`
// (from `@main`) registers the app's scenes. Same sources as the Android apps.
package.targets += [.target(name: "DemoWinUI", dependencies: ["SwiftUI"], path: "Sources/DemoAndroid")]
package.products += [.library(name: "DemoWinUI", type: .dynamic, targets: ["DemoWinUI"])]
package.targets += [.target(name: "GalleryWinUI", dependencies: ["SwiftUI"], path: "Sources/GalleryAndroid")]
package.products += [.library(name: "GalleryWinUI", type: .dynamic, targets: ["GalleryWinUI"])]
// Desktop/drawing feature tour (commands, shortcuts, file dialogs, effects) and the reference app.
package.targets += [.target(name: "FeatureTourWinUI", dependencies: ["SwiftUI"], path: "Sources/FeatureTour")]
package.products += [.library(name: "FeatureTourWinUI", type: .dynamic, targets: ["FeatureTourWinUI"])]
package.targets += [.target(name: "ReferenceAppWinUI", dependencies: ["SwiftUI"], path: "Sources/ReferenceApp")]
package.products += [.library(name: "ReferenceAppWinUI", type: .dynamic, targets: ["ReferenceAppWinUI"])]
#else
if !crossCompiling {
    package.targets += [
        .testTarget(name: "SwiftUIAppKitTests", dependencies: ["SwiftUI"]),
    ]
} else {
    // Android apps are shared libraries the Kotlin host loads (`lib<Name>.so`); the library's
    // `main` (from `@main`) registers the app's scenes. Same sources as the macOS Demo.
    package.targets += [.target(name: "DemoAndroid", dependencies: ["SwiftUI"])]
    package.products += [.library(name: "DemoAndroid", type: .dynamic, targets: ["DemoAndroid"])]
    // Android smoke-test app (animations, gestures, presentations, timers, text input).
    package.targets += [.target(name: "GalleryAndroid", dependencies: ["SwiftUI"])]
    package.products += [.library(name: "GalleryAndroid", type: .dynamic, targets: ["GalleryAndroid"])]
}
#endif
