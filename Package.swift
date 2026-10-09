// swift-tools-version: 6.2
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

let package = Package(
    name: "SwiftUI2",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwiftUI2", targets: ["SwiftUI2"]),
        .library(name: "SwiftUI2Core", targets: ["SwiftUI2Core"]),
        .library(name: "SwiftUI2Headless", targets: ["SwiftUI2Headless"]),
        .executable(name: "parity-recorder", targets: ["parity-recorder"]),
        .executable(name: "ReferenceApp", targets: ["ReferenceApp"]),
        .executable(name: "Demo", targets: ["Demo"]),
        .executable(name: "ReferenceApp2", targets: ["ReferenceApp2"]),
    ],
    targets: [
        .target(name: "SwiftUI2Graph"),
        .target(name: "SwiftUI2Core", dependencies: ["SwiftUI2Graph"]),
        .target(name: "SwiftUI2Headless", dependencies: ["SwiftUI2Core"]),
        .target(name: "SwiftUI2AppKit", dependencies: ["SwiftUI2Core"]),
        // SwiftData's SwiftUI integration (@Query, .modelContainer) on Apple platforms.
        .target(name: "SwiftUI2SwiftData", dependencies: ["SwiftUI2Core"]),
        .target(
            name: "SwiftUI2",
            dependencies: [
                "SwiftUI2Core",
                .target(name: "SwiftUI2AppKit", condition: .when(platforms: [.macOS])),
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
        .testTarget(name: "SwiftUI2AppKitTests", dependencies: ["SwiftUI2"]),
        .testTarget(
            name: "ParityTests",
            dependencies: ["ParityScenarios", "SwiftUI2Headless"],
            resources: [.copy("Golden")]
        ),
    ]
)
