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

/// Set by `Android/scripts/swift-android`: Apple-SwiftUI-only targets (the reference app, the
/// parity recorder) and the AppKit tests can't be cross-compiled, so they are left out.
let crossCompiling = Context.environment["SWIFTUI_CROSS_COMPILE"] != nil

let package = Package(
    name: "SwiftUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        .library(name: "_SwiftUICore", targets: ["_SwiftUICore"]),
        .library(name: "SwiftUICharts", targets: ["SwiftUICharts"]),
        .library(name: "SwiftUIHeadless", targets: ["SwiftUIHeadless"]),
        .executable(name: "parity-recorder", targets: ["parity-recorder"]),
        .executable(name: "ReferenceApp", targets: ["ReferenceApp"]),
        .executable(name: "Demo", targets: ["Demo"]),
        .executable(name: "ReferenceApp2", targets: ["ReferenceApp2"]),
    ],
    dependencies: [
        // Macros (@Entry, #Preview).
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
        // Stand-ins for Apple-only modules (UniformTypeIdentifiers, ...) on other platforms.
        .package(path: "Compat"),
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
        .target(name: "SwiftUIPortability", dependencies: [
            .product(name: "CoreTransferable", package: "Compat", condition: .when(platforms: nonApple)),
            .product(name: "UniformTypeIdentifiers", package: "Compat", condition: .when(platforms: nonApple)),
        ]),
        .target(
            name: "_SwiftUICore",
            dependencies: [
                "SwiftUIGraph", "SwiftUIMacros",
                .target(name: "SwiftUIPortability", condition: .when(platforms: nonApple)),
                .product(name: "UniformTypeIdentifiers", package: "Compat", condition: .when(platforms: nonApple)),
                .product(name: "Combine", package: "Compat", condition: .when(platforms: nonApple)),
            ]
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
        // GTK 3 backend (Linux): `apt install libgtk-3-dev`.
        .systemLibrary(name: "CGtk3", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])]),
        .target(name: "SwiftUIGtk", dependencies: ["_SwiftUICore", .target(name: "CGtk3", condition: .when(platforms: [.linux]))]),
        // A Swift Charts subset (import SwiftUICharts instead of Charts).
        .target(name: "SwiftUICharts", dependencies: ["_SwiftUICore"]),
        // SwiftData's SwiftUI integration (@Query, .modelContainer) on Apple platforms.
        .target(name: "SwiftUISwiftData", dependencies: ["_SwiftUICore"]),
        .target(
            name: "SwiftUI",
            dependencies: [
                "_SwiftUICore",
                .target(name: "SwiftUIAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "SwiftUIAndroid", condition: .when(platforms: [.android])),
                .target(name: "SwiftUIGtk", condition: .when(platforms: [.linux])),
                .target(name: "SwiftUIWinUI", condition: .when(platforms: [.windows])),
                .target(name: "SwiftUISwiftData", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),

        // Parity: the same scenario sources (Parity/Scenarios, symlinked into both targets)
        // are compiled once against Apple's SwiftUI and once against SwiftUI.
        .target(
            name: "ParityScenarios",
            dependencies: ["SwiftUI", "SwiftUIHeadless"]
        ),
        .target(name: "ParityScenariosSwiftUI"),
        .executableTarget(name: "parity-recorder", dependencies: ["ParityScenariosSwiftUI"]),

        // Large reference app written against Apple's SwiftUI. It is the behavioural spec:
        // every screen in it must eventually run unchanged on SwiftUI.
        .executableTarget(name: "ReferenceApp"),
        // The same reference app sources compiled against SwiftUI (the porting target).
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

#if os(Linux)
let buildingOnLinux = true
#else
let buildingOnLinux = false
#endif

#if os(Windows)
let buildingOnWindows = true
#else
let buildingOnWindows = false
#endif

if buildingOnLinux {
    // Native Linux build (GTK backend): Apple-SwiftUI-only and other platforms' backends are left out.
    let excluded: Set<String> = ["ReferenceApp", "parity-recorder", "ParityScenariosSwiftUI", "SwiftUIAppKit", "SwiftUISwiftData",
                                 "CSwiftUIAndroid", "SwiftUIAndroid"]
    package.targets.removeAll { excluded.contains($0.name) }
    package.products.removeAll { excluded.contains($0.name) }
    for target in package.targets where target.name == "SwiftUI" {
        target.dependencies = ["_SwiftUICore", "SwiftUIGtk"]
    }
    // GTK smoke-test app (the Android Gallery's sources).
    package.targets += [.executableTarget(name: "GalleryGtk", dependencies: ["SwiftUI"])]
    package.products += [.executable(name: "GalleryGtk", targets: ["GalleryGtk"])]
} else if buildingOnWindows {
    // Native Windows build (WinUI backend): Apple-SwiftUI-only and other platforms' backends are left out.
    let excluded: Set<String> = ["ReferenceApp", "ReferenceApp2", "Demo", "parity-recorder", "ParityScenariosSwiftUI",
                                 "SwiftUIAppKit", "SwiftUISwiftData", "CSwiftUIAndroid", "SwiftUIAndroid", "CGtk3", "SwiftUIGtk"]
    package.targets.removeAll { excluded.contains($0.name) }
    package.products.removeAll { excluded.contains($0.name) }
    for target in package.targets where target.name == "SwiftUI" {
        target.dependencies = ["_SwiftUICore", "SwiftUIWinUI"]
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
} else if !crossCompiling {
    package.targets += [
        .testTarget(name: "SwiftUIAppKitTests", dependencies: ["SwiftUI"]),
    ]
} else {
    let appleOnly: Set<String> = ["ReferenceApp", "parity-recorder", "ParityScenariosSwiftUI"]
    package.targets.removeAll { appleOnly.contains($0.name) }
    package.products.removeAll { appleOnly.contains($0.name) }
    // Android apps are shared libraries the Kotlin host loads (`lib<Name>.so`); the library's
    // `main` (from `@main`) registers the app's scenes. Same sources as the macOS Demo.
    package.targets += [.target(name: "DemoAndroid", dependencies: ["SwiftUI"])]
    package.products += [.library(name: "DemoAndroid", type: .dynamic, targets: ["DemoAndroid"])]
    // Android smoke-test app (animations, gestures, presentations, timers, text input).
    package.targets += [.target(name: "GalleryAndroid", dependencies: ["SwiftUI"])]
    package.products += [.library(name: "GalleryAndroid", type: .dynamic, targets: ["GalleryAndroid"])]
}
