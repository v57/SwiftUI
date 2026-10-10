// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// Layering (see ARCHITECTURE.md):
//
//   SwiftUI2Graph      dependency engine (attributes, subgraphs, invalidation). No UI knowledge.
//   SwiftUI2Core       the SwiftUI API surface + view graph + layout + render tree. Platform independent.
//   SwiftUI2Headless   deterministic in-memory backend used by tests and parity runs.
//   SwiftUI2AppKit     macOS backend (NSView based).
//   SwiftUI2           umbrella module apps import; re-exports Core + the platform backend.
//
// Future backends (SwiftUI2Gtk, SwiftUI2WinUI, SwiftUI2Android) plug in exactly like SwiftUI2AppKit.

let nonApple: [Platform] = [.android, .linux, .windows]

/// Set by `Android/scripts/swift-android`: Apple-SwiftUI-only targets (the reference app, the
/// parity recorder) and the AppKit tests can't be cross-compiled, so they are left out.
let crossCompiling = Context.environment["SWIFTUI2_CROSS_COMPILE"] != nil

let package = Package(
    name: "SwiftUI2",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftUI2", targets: ["SwiftUI2"]),
        .library(name: "SwiftUI2Core", targets: ["SwiftUI2Core"]),
        .library(name: "SwiftUI2Charts", targets: ["SwiftUI2Charts"]),
        .library(name: "SwiftUI2Headless", targets: ["SwiftUI2Headless"]),
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
        .target(name: "SwiftUI2Graph"),
        .macro(
            name: "SwiftUI2Macros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        // Foundation/CoreGraphics types missing from swift-corelibs-foundation (empty on Apple).
        .target(name: "SwiftUI2Portability"),
        .target(
            name: "SwiftUI2Core",
            dependencies: [
                "SwiftUI2Graph", "SwiftUI2Macros",
                .target(name: "SwiftUI2Portability", condition: .when(platforms: nonApple)),
                .product(name: "UniformTypeIdentifiers", package: "Compat", condition: .when(platforms: nonApple)),
                .product(name: "Combine", package: "Compat", condition: .when(platforms: nonApple)),
            ]
        ),
        .target(name: "SwiftUI2Headless", dependencies: ["SwiftUI2Core"]),
        .target(name: "SwiftUI2AppKit", dependencies: ["SwiftUI2Core"]),
        // Android backend: Swift renderer + JNI glue; the Kotlin host lives in Android/.
        .target(
            name: "CSwiftUI2Android",
            linkerSettings: [.linkedLibrary("android", .when(platforms: [.android])), .linkedLibrary("log", .when(platforms: [.android]))]
        ),
        .target(name: "SwiftUI2Android", dependencies: ["SwiftUI2Core", "CSwiftUI2Android"]),
        // A Swift Charts subset (import SwiftUI2Charts instead of Charts).
        .target(name: "SwiftUI2Charts", dependencies: ["SwiftUI2Core"]),
        // SwiftData's SwiftUI integration (@Query, .modelContainer) on Apple platforms.
        .target(name: "SwiftUI2SwiftData", dependencies: ["SwiftUI2Core"]),
        .target(
            name: "SwiftUI2",
            dependencies: [
                "SwiftUI2Core",
                .target(name: "SwiftUI2AppKit", condition: .when(platforms: [.macOS])),
                .target(name: "SwiftUI2Android", condition: .when(platforms: [.android])),
                // Apple-only modules apps import, as stand-ins elsewhere (Compat/).
                .product(name: "Darwin", package: "Compat", condition: .when(platforms: nonApple)),
                .target(name: "SwiftUI2SwiftData", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),

        // Parity: the same scenario sources (Parity/Scenarios, symlinked into both targets)
        // are compiled once against Apple's SwiftUI and once against SwiftUI2.
        .target(
            name: "ParityScenarios",
            dependencies: ["SwiftUI2", "SwiftUI2Headless"],
            swiftSettings: [.define("SWIFTUI2")]
        ),
        .target(name: "ParityScenariosSwiftUI"),
        .executableTarget(name: "parity-recorder", dependencies: ["ParityScenariosSwiftUI"]),

        // Large reference app written against Apple's SwiftUI. It is the behavioural spec:
        // every screen in it must eventually run unchanged on SwiftUI2.
        .executableTarget(name: "ReferenceApp"),
        // The same reference app sources compiled against SwiftUI2 (the porting target).
        .executableTarget(name: "ReferenceApp2", dependencies: ["SwiftUI2"], swiftSettings: [.define("SWIFTUI2")]),
        // Small app running on SwiftUI2 + AppKit backend.
        .executableTarget(name: "Demo", dependencies: ["SwiftUI2"]),

        .testTarget(name: "SwiftUI2GraphTests", dependencies: ["SwiftUI2Graph"]),
        .testTarget(name: "SwiftUI2CoreTests", dependencies: ["SwiftUI2Core", "SwiftUI2Headless"]),
        .testTarget(
            name: "ParityTests",
            dependencies: ["ParityScenarios", "SwiftUI2Headless"],
            resources: [.copy("Golden")]
        ),
    ]
)

if !crossCompiling {
    package.targets += [
        .testTarget(name: "SwiftUI2AppKitTests", dependencies: ["SwiftUI2"]),
    ]
} else {
    let appleOnly: Set<String> = ["ReferenceApp", "parity-recorder", "ParityScenariosSwiftUI"]
    package.targets.removeAll { appleOnly.contains($0.name) }
    package.products.removeAll { appleOnly.contains($0.name) }
    // Android apps are shared libraries the Kotlin host loads (`lib<Name>.so`); the library's
    // `main` (from `@main`) registers the app's scenes. Same sources as the macOS Demo.
    package.targets += [.target(name: "DemoAndroid", dependencies: ["SwiftUI2"])]
    package.products += [.library(name: "DemoAndroid", type: .dynamic, targets: ["DemoAndroid"])]
}
