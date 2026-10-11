// swift-tools-version: 6.2
import PackageDescription

// Targets built against Apple's SwiftUI. They live outside the SwiftUI package because SwiftPM
// puts every module of a build on one search path, ahead of the SDK: next to this repository's
// `SwiftUI` module, their `import SwiftUI` would resolve to it instead of Apple's framework.
// Run from the repository root:
//
//   swift run --package-path AppleSwiftUI ReferenceApp      # the spec app on Apple SwiftUI
//   swift run --package-path AppleSwiftUI parity-recorder   # re-record Parity/Golden

let package = Package(
    name: "AppleSwiftUI",
    platforms: [.macOS(.v14)],
    targets: [
        // The parity scenarios (Parity/Scenarios, symlinked) compiled against Apple's SwiftUI;
        // the SwiftUI package compiles the same sources against SwiftUI (ParityScenarios).
        .target(name: "AppleParityScenarios"),
        .executableTarget(name: "parity-recorder", dependencies: ["AppleParityScenarios"]),

        // Large reference app (../Sources/ReferenceApp, symlinked) written against Apple's SwiftUI.
        // It is the behavioural spec: the SwiftUI package builds the same sources as ReferenceApp2.
        .executableTarget(name: "ReferenceApp"),
    ]
)
