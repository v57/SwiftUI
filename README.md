# SwiftUI

A re-implementation of SwiftUI in Swift — same API, same update semantics — with pluggable
platform backends: **AppKit** (macOS), **GTK 3** (Linux), **Android** and **WinUI 3** (Windows).

```swift
import SwiftUI

@Observable final class Model { var count = 0 }

@main struct CounterApp: App {
    @State private var model = Model()
    var body: some Scene {
        WindowGroup("Counter") {
            VStack {
                Text("\(model.count)").font(.largeTitle)
                Button("Increment") { model.count += 1 }
            }
            .padding()
        }
    }
}
```

## What's here

| Path | |
|------|--|
| `Sources/SwiftUIGraph` | Dependency engine: attributes, subgraphs, push-dirty / pull / equality cut-off |
| `Sources/_SwiftUICore` | SwiftUI API, view graph, identity, state & observation, layout, render tree |
| `Sources/SwiftUIAppKit` | macOS backend (`NSHostingView`, App runner) |
| `Sources/SwiftUIGtk` | Linux backend (GTK 3: cairo/Pango drawing, native text entry; `Linux/scripts/vm`) |
| `Sources/SwiftUIAndroid`, `Android/` | Android backend: Swift renderer + JNI, Kotlin host, build scripts |
| `Sources/SwiftUIWinUI`, `Windows/` | Windows backend: Swift renderer + C exports, C# WinUI 3 host, build scripts |
| `Sources/Combine`, `UniformTypeIdentifiers`, `CoreTransferable` | Stand-ins for these Apple modules on Linux, Windows and Android |
| `Sources/SwiftUIHeadless` | Deterministic in-memory backend + `TestHost` for tests |
| `Sources/SwiftUI` | Umbrella module apps import |
| `Parity/` | Scenarios compiled against **both** Apple SwiftUI and this SwiftUI, golden counts |
| `Sources/ReferenceApp` | Large app on Apple SwiftUI — the behavioural spec to port |
| `AppleSwiftUI/` | Separate package for the targets built on Apple's SwiftUI (reference app, parity recorder) |
| `Sources/Demo` | SwiftUI demo app on AppKit |

Supported today (see `Sources/ReferenceApp` for every feature in use — it compiles unchanged
against both Apple SwiftUI and this SwiftUI):

* **Structure & state** — `View`/`ViewBuilder` (parameter packs), `TupleView`, `if`/`else`,
  `Optional`, `ForEach` (+ `onDelete`), `Group`, `AnyView`, `.id`, `EquatableView`, `@State`,
  `@Binding`, `@Environment` (keys and `Observable` objects), `@Observable`, `@Bindable`,
  `ObservableObject` (`@ObservedObject`, `@StateObject`, `@EnvironmentObject`), `@FocusState`,
  `@GestureState`, `@Namespace`, `@AppStorage`, `@SceneStorage`, preferences & anchors,
  `onGeometryChange`, coordinate spaces.
* **Layout** — `Layout` protocol, `AnyLayout`, `VStack/HStack/ZStack`, *lazy* `LazyVStack/LazyHStack`
  (viewport-driven, matches SwiftUI's row counts), `LazyVGrid/LazyHGrid`, `Grid/GridRow`,
  `ViewThatFits`, `GeometryReader`, `ScrollView` + `ScrollViewReader`, `Spacer`, `Divider`, all
  frame/padding/offset/position/aspectRatio/alignmentGuide/layoutPriority/fixedSize modifiers,
  overlay/background (layout-isolated), `safeAreaInset`.
* **Controls** — `Text` (styled concatenation, dates, formats), `Image`, `Label`, `Button` (+
  `ButtonStyle`/`PrimitiveButtonStyle`, built-in styles, roles, keyboard shortcuts), `Toggle` (+
  `ToggleStyle`), `TextField`, `SecureField`, `TextEditor`, `Slider`, `Stepper`, `Picker` (menu,
  segmented, radio, inline), `DatePicker`, `ColorPicker`, `ProgressView`, `Gauge`, `Link`, `Menu`,
  `LabeledContent`, `ContentUnavailableView`, `GroupBox`, `DisclosureGroup`, `OutlineGroup`,
  `ControlGroup`, `Canvas`, `TimelineView`, `Table`.
* **Containers & navigation** — `List` (lazy, selection), `Form`/`Section` (macOS grouped style),
  `TabView`/`Tab`, `NavigationStack` (path, `NavigationLink`, `navigationDestination`),
  `NavigationSplitView`, `navigationTitle` (window title), toolbars, `searchable`.
* **Presentation** — sheets, alerts, confirmation dialogs, popovers, menus, context menus,
  `dismiss` — rendered by SwiftUI itself, so every backend gets them.
* **Animation** — transactions, `withAnimation` (+ completion), `.animation(_:value:)`,
  `.transaction`, curves (linear/bezier/springs/repeat), `Animatable` views & shapes (body per
  frame), transitions (opacity/scale/move/slide/push/offset/asymmetric/combined),
  `matchedGeometryEffect`, `phaseAnimator`.
* **Gestures** — tap (count/location), long press, drag, simultaneous/sequenced/exclusive, hover.
* **Styling** — colors, gradients (linear/radial/angular/elliptical), materials (as translucent
  fills), shapes (trim, inset, stroke styles, transforms), opacity/clip/shadow/scale/rotation.

Not implemented by design: shaders, blur and compositing filters, Apple-only views (Maps, Photos,
ShareLink, ...). SwiftData is a stand-in off Apple platforms (`@Model`, containers and contexts over a JSON file;
`@Query` through SwiftUI), below.

## Libraries

Products an app or library can import. The stand-ins for Apple frameworks are defined only when building for
Linux, Windows or Android (on Apple platforms the real framework is used); add them to a target only there.

| Library | Purpose | Platforms | Import |
|---------|---------|-----------|--------|
| [SwiftUI](docs/SwiftUI.md) | SwiftUI's API with the platform's backend; also gives Combine, UniformTypeIdentifiers, CoreTransferable, CoreGraphics and SwiftUIPortability off Apple platforms | macOS (AppKit), Linux (GTK 3), Windows (WinUI 3), Android | `import SwiftUI` |
| [SwiftUIHeadless](docs/SwiftUIHeadless.md) | `TestHost`: views in memory for tests, with deterministic updates and text metrics | all of the above | `import SwiftUIHeadless` |
| [SwiftUICharts](docs/SwiftUICharts.md) | A subset of Swift Charts drawn with `Canvas` | all of the above | `import SwiftUICharts` |
| [Charts](docs/SwiftUICharts.md) | `SwiftUICharts` under Apple's module name (shares its page) | Linux, Windows, Android | `import Charts` |
| [CryptoKit](docs/CryptoKit.md) | swift-crypto, plus `SecureEnclave` keys sealed to the device's user | Linux, Windows, Android | `import CryptoKit` |
| [Network](docs/Network.md) | `NWConnection` (TCP, TLS, UDP) and `NWListener` on sockets | Linux, Windows (Android: no TLS) | `import Network` |
| [SwiftData](docs/SwiftData.md) | `@Model`, containers and contexts over a JSON file | Linux, Windows, Android | `import SwiftData` |
| [os](docs/os.md) | `Logger`, `os_log`, signposts (dropped) and `OSAllocatedUnfairLock` | Linux, Windows, Android | `import os` |
| [SQLite3](docs/SQLite3.md) | SQLite's C API | Linux, Windows, Android | `import SQLite3` |
| [SwiftUIPortability](docs/SwiftUIPortability.md) | Foundation API swift-corelibs-foundation lacks, `ChildProcess`, `DirectoryWatcher` | Linux, Windows, Android | `import SwiftUIPortability` |
| [SecretService](docs/SecretService.md) | Secrets in the freedesktop Secret Service (libsecret) | Linux | `import SecretService` |

`_SwiftUICore` is also a product: the platform-independent core the backends build on. Apps don't import it;
`SwiftUI` and `SwiftUIHeadless` re-export it. `Demo` and `ReferenceApp2` are sample executables.

## Using SwiftUI in an app

Apps depend on the package with SwiftPM on every platform and keep writing `import SwiftUI`. On macOS and
Linux the app is an executable. On Android and Windows it is a dynamic library (`lib<App>.so`, `<App>.dll`)
that SwiftUI's host app loads (Kotlin on Android, C# WinUI 3 on Windows), so the product type depends on
the platform:

```swift
// swift-tools-version: 6.2
import PackageDescription

// A manifest can't see the platform it builds for, so an Android cross-compile from macOS sets
// SWIFTUI_CROSS_COMPILE (the Android build script does). SwiftUI's own manifest reads it too.
#if os(Windows)
let hosted = true
#else
let hosted = Context.environment["SWIFTUI_CROSS_COMPILE"] != nil
#endif
let swiftUI: [Target.Dependency] = [.product(name: "SwiftUI", package: "SwiftUI")]

let package = Package(
    name: "Hello",
    platforms: [.macOS(.v14)],
    products: [
        hosted ? .library(name: "Hello", type: .dynamic, targets: ["Hello"])
               : .executable(name: "Hello", targets: ["Hello"]),
    ],
    dependencies: [
        .package(url: "https://github.com/v57/SwiftUI", branch: "main"),
    ],
    targets: [
        hosted ? .target(name: "Hello", dependencies: swiftUI)
               : .executableTarget(name: "Hello", dependencies: swiftUI),
    ]
)
```

`Sources/Hello/Hello.swift` is the counter app above. Then, per platform:

**macOS** (AppKit; macOS 14+, Swift 6.2+):

```bash
swift run Hello
```

Keep code that should use Apple's SwiftUI in a separate package: SwiftPM searches the modules it builds
before the SDK, so in a package that also builds this SwiftUI, `import SwiftUI` finds this one.

**Linux** (GTK 3; tested on Ubuntu 24.04 with Swift 6.3). The package's system libraries need their dev packages:
GTK 3 (`SwiftUIGtk`), libsecret (`SecretService`, the keychain stand-in CryptoKit and VaultKit use), SQLite
(`SQLite3`, the system's) and OpenSSL (`Network`'s TLS):

```bash
sudo apt install libgtk-3-dev libsecret-1-dev libsqlite3-dev libssl-dev
swift run Hello
```

**Android** (cross-compiled on macOS; installs on a device connected over adb). Needs the swift.org
toolchain and the Swift SDK for Android of the same version (6.3.3), a JDK (21) and Gradle; the expected
locations are in `Android/scripts/env.sh`, each overridable with its environment variable. `build-app`
compiles `libHello.so`, packages it with the Swift runtime and SwiftUI's Kotlin host into an APK, installs
and launches it (`--no-install` only builds; `-c release` for a smaller, faster build):

```bash
swift package resolve
.build/checkouts/SwiftUI/Android/scripts/build-app --package-path . --product Hello \
    --app-id com.example.hello --label Hello
```

**Windows** (WinUI 3; Windows 11 arm64 or x64). Needs Swift for Windows (6.4), Visual Studio Build Tools
with the Windows SDK, Git and the .NET SDK (10); `Windows/scripts/setup-toolchain.ps1` installs them.
`build-app.ps1` builds `Hello.dll` and the WinUI host and stages both, with the Swift runtime, in
`.build\winui\Hello` (`-Run` starts `SwiftUIHost.exe`; `-Configuration release` stages a release cut for size: a
Native AOT host, stripped DLLs, ICU data for the app's languages only, and only the runtime files and WinUI translations
the app uses):

```powershell
swift package resolve
.build\checkouts\SwiftUI\Windows\scripts\build-app.ps1 -PackagePath . -Product Hello -Run
```

## Docs

* [docs/SwiftUI.md](docs/SwiftUI.md) — using SwiftUI in an app: backends, building on each platform, testing
* [ARCHITECTURE.md](ARCHITECTURE.md) — how updates, identity and layout boundaries work
* [docs/PARITY.md](docs/PARITY.md) — verifying behaviour and update counts against Apple SwiftUI
* [docs/BACKENDS.md](docs/BACKENDS.md) — writing the GTK / WinUI / Android backends

## Build & test

```bash
swift test                # graph, core, AppKit and parity suites (all must pass)
swift run Demo            # SwiftUI + AppKit
swift run ReferenceApp2   # the reference app on SwiftUI
swift run --package-path AppleSwiftUI ReferenceApp     # the same app on Apple SwiftUI
swift run --package-path AppleSwiftUI parity-recorder  # re-record the golden counts
```

Requires Swift 6.2+ (developed with Swift 6.4 / Xcode 27, macOS 15+).

## License

MIT. See [LICENSE](LICENSE).
