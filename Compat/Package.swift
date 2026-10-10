// swift-tools-version: 6.2
import PackageDescription

// API-compatible stand-ins for Apple-only modules, linked on non-Apple platforms only (the root
// package depends on these products with `.when(platforms: [.android, .linux, .windows])`), so
// unchanged `import UniformTypeIdentifiers` / `import Combine` code compiles there. Apple
// platforms keep the real frameworks.

let nonApple: [Platform] = [.android, .linux, .windows]

/// A module named `Combine` can't even be built for Apple platforms (Apple's Dispatch imports the
/// real one), so it only exists when cross-compiling (`Android/scripts/swift-android` sets this);
/// on macOS the product is an empty placeholder that nothing links.
let crossCompiling = Context.environment["SWIFTUI2_CROSS_COMPILE"] != nil

let package = Package(
    name: "SwiftUI2Compat",
    products: [
        .library(name: "UniformTypeIdentifiers", targets: ["UniformTypeIdentifiers"]),
        .library(name: "Combine", targets: [crossCompiling ? "Combine" : "CombineUnavailableOnApplePlatforms"]),
        .library(name: "Darwin", targets: [crossCompiling ? "Darwin" : "DarwinUnavailableOnApplePlatforms"]),
    ],
    targets: [
        .target(name: "UniformTypeIdentifiers"),
        .target(name: "CombineUnavailableOnApplePlatforms"),
        .target(name: "DarwinUnavailableOnApplePlatforms"),
        .testTarget(name: "CompatTests", dependencies: ["UniformTypeIdentifiers"] + (crossCompiling ? ["Combine"] : [])),
    ]
)

if crossCompiling {
    package.targets += [
        // Combine: OpenCombine 0.14.0 (MIT, Sources/Combine/LICENSE-OpenCombine.txt) vendored as
        // one module named Combine, with its Apple spellings always on (DispatchQueue/RunLoop as
        // schedulers, Timer.publish, NotificationCenter.publisher, URLSession publishers).
        // Darwin: re-exports the platform C library (POSIX).
        .target(name: "Darwin"),
        .target(name: "COpenCombineHelpers"),
        .target(name: "Combine", dependencies: ["COpenCombineHelpers"], exclude: ["LICENSE-OpenCombine.txt"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
}
