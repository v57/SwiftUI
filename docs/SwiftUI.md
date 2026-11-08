# SwiftUI

The `SwiftUI` product is the module an app imports. It is a re-implementation of Apple's SwiftUI API in Swift, with
the same update semantics, and a backend per platform: AppKit on macOS, GTK 3 on Linux, WinUI 3 on Windows and
Android views on Android. An app writes `import SwiftUI` as it would on a Mac, and the same source builds against
Apple's framework on Apple platforms and against this package elsewhere.

It is not a port of every Apple framework. Apple-only views (Maps, Photos, `ShareLink`, ...), shaders, blur and
compositing filters are left out by design, and there is no UIKit backend: on iOS and iPadOS an app uses Apple's
SwiftUI. How the view graph, identity and layout work is in [ARCHITECTURE.md](../ARCHITECTURE.md).

Other libraries in this package: [SwiftUIHeadless](SwiftUIHeadless.md) (testing views),
[SwiftUICharts](SwiftUICharts.md), and stand-ins for Apple frameworks off Apple platforms
([CryptoKit](CryptoKit.md), [Network](Network.md), [SwiftData](SwiftData.md), [os](os.md), [SQLite3](SQLite3.md),
[SwiftUIPortability](SwiftUIPortability.md), [SecretService](SecretService.md)). The full list is in the
[README](../README.md#libraries).

## Getting started

### Adding the package

There are two ways to depend on it.

**This SwiftUI on every platform**, macOS included (where it runs on AppKit). The README's
[Using SwiftUI in an app](../README.md#using-swiftui-in-an-app) has the manifest: the app is an executable on macOS
and Linux, and a dynamic library on Windows and Android, where SwiftUI's host app loads it.

**Apple's SwiftUI on Apple platforms, this one elsewhere.** Add the dependency only when the build is off Apple
platforms. On Apple platforms `import SwiftUI` then finds Apple's framework in the SDK; on Linux, Windows and Android
it finds this module. A manifest runs on the build machine, so `#if os(...)` names the host, not the destination; an
Android build cross-compiles from macOS and sets `SWIFTUI_CROSS_COMPILE` (`Android/scripts/swift-android` does):

```swift
// swift-tools-version: 6.2
import PackageDescription

#if os(Linux) || os(Windows)
let offApple = true
#else
let offApple = Context.environment["SWIFTUI_CROSS_COMPILE"] != nil
#endif

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MyAppUI", targets: ["MyAppUI"])],
    targets: [.target(name: "MyAppUI")]
)

if offApple {
    package.dependencies += [.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")]
    for target in package.targets where target.name == "MyAppUI" {
        target.dependencies += [.product(name: "SwiftUI", package: "SwiftUI")]
    }
}
```

Keep code that must use Apple's SwiftUI out of any package that also builds this one: SwiftPM searches the modules
it builds before the SDK, so next to this package's `SwiftUI` module `import SwiftUI` resolves to it. Add the app's
entry point the same way: an Xcode project (or an Apple-only package) builds the Apple app; off Apple platforms an
executable target (Linux) or a dynamic library (Windows, Android) holds the `@main` file. The v57 apps keep their
code in a library in an `App/` package and add those targets per platform, as
[Apps on Linux](BACKENDS.md#apps-on-linux) describes.

Off Apple platforms, Foundation doesn't re-export Combine, and SwiftUI doesn't re-export AppKit. A file that uses
`ObservableObject` or `@Published` with only `import Foundation` needs `import Combine` (or `import SwiftUI`) there.
Frameworks an app imports directly (`CryptoKit`, `Network`, `os`, ...) are separate products of this package; add
them in the same `if offApple` branch (see the [README's table](../README.md#libraries)).

### A minimal app

```swift
import SwiftUI

@main struct HelloApp: App {
    var body: some Scene {
        WindowGroup("Hello") {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var name = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Text("Hello, \(name)")
        }
        .padding()
    }
}
```

## Choosing a backend

There is nothing to choose at run time: the `SwiftUI` module depends on one backend per platform and re-exports it.

| Platform | Backend module | Host |
|---|---|---|
| macOS 14+ | `SwiftUIAppKit` | `NSView`s; `import SwiftUI` also gives AppKit, as Apple's does |
| Linux | `SwiftUIGtk` | GTK 3: one canvas per window drawn with cairo and Pango, native text entry while editing |
| Windows | `SwiftUIWinUI` | the C# WinUI 3 host in `Windows/SwiftUIHost`, which loads the app's DLL |
| Android | `SwiftUIAndroid` | the Kotlin host in `Android/`, which loads `lib<App>.so` |
| Tests | `SwiftUIHeadless` | in memory, with deterministic text metrics ([SwiftUIHeadless](SwiftUIHeadless.md)) |

`App.main()` starts the platform's runner: on macOS and Linux it runs the main loop; on Windows and Android it
registers the app's scenes and returns to the host, which owns the loop. A backend's own API (for example
`NSViewRepresentable` on macOS or `GtkWidgetRepresentable` on Linux) only exists on its platform, so wrap its use in
`#if os(...)`. To write a backend, see [BACKENDS.md](BACKENDS.md).

## Building and running an app

The README lists each platform's toolchain. The scripts below live in this repository; from an app's package, run
them from the checkout SwiftPM made (`swift package resolve`, then `.build/checkouts/SwiftUI/...`).

**macOS.** `swift run <Product>`.

**Linux** (GTK 3; tested on Ubuntu 24.04 and 26.04). Install `libgtk-3-dev`. Some stand-ins need more system
libraries: `libsecret-1-dev` for [CryptoKit](CryptoKit.md) and [SecretService](SecretService.md),
`libsqlite3-dev` for [SQLite3](SQLite3.md), and OpenSSL's headers (`libssl-dev`) for TLS in [Network](Network.md).
`swift run <Product>` runs the app in place. `Linux/scripts/build-app` builds it and stages a runnable folder in
`<package>/.build/linux/<Product>/`: the executable, its resource bundles, the Material Symbols font that draws
`Image(systemName:)` (from `Android/scripts/fetch-assets` or an installed copy; without it symbols show
placeholders), an `Info.plist` with the bundle identifier and version
from the app's Xcode project, so `UserDefaults` are the app's own, and a `.desktop` file:

```bash
Linux/scripts/build-app --package ~/Projects/MyApp -c release --run MyApp
```

`--static` links the Swift runtime into the executable, `--install` adds the `.desktop` file to the user's
applications, and `--script <file>` runs a script against the app (under Xvfb when there is no display).

**Windows** (WinUI 3; Windows 11, arm64 or x64). `Windows/scripts/setup-toolchain.ps1` installs Swift, the Visual
Studio Build Tools, Git and the .NET SDK. `build-app.ps1` builds the app's DLL and the host and stages both, with the
Swift runtime, in `<package>\.build\winui\<Product>`:

```powershell
.build\checkouts\SwiftUI\Windows\scripts\build-app.ps1 -PackagePath . -Product MyApp -Run
```

`-Configuration release` cuts the folder for size (a Native AOT host, stripped DLLs whose symbols go to
`<Product>.symbols`, ICU data for the app's languages only). `-FullICU` keeps the toolchain's ICU. `-Script <file>`
and `-Log <file>` are passed to the host.

**Android** (arm64 devices, Android 9 / API 28 and later). Cross-compiled on macOS with the swift.org toolchain and
the Swift SDK for Android of the same version, a JDK and Gradle; `Android/scripts/env.sh` lists the expected
locations, each overridable with its environment variable. `build-app` builds `lib<Product>.so`, packages it with
the Swift runtime and the Kotlin host into an APK, and installs and launches it on a device connected over adb (a
physical device; it skips emulators). `--no-install` only builds; `-c release` strips the libraries:

```bash
.build/checkouts/SwiftUI/Android/scripts/build-app --package-path . --product MyApp \
    --app-id com.example.myapp --label MyApp
```

### Driving a running app

- **Script mode.** `<app> --script <file>` on Linux (or `SWIFTUI_SCRIPT=<file>`) and `SwiftUIHost.exe --script
  <file>` on Windows run one command per line: wait, tap a text, type, take a screenshot, dump the render tree. The
  GTK commands are listed in [BACKENDS.md](BACKENDS.md#script-mode); the WinUI host has a subset (`wait`,
  `screenshot`, `dump`, `tap`, `tapat`, `type`, `fill`, `keys`, `back`, `log`, `exit`). Smoke scripts are in
  `Linux/tests`.
- **Element channel.** With `SWIFTUI_INSPECT=1` an app on Linux or Windows answers its visible elements as JSON on a
  local socket or named pipe that only the same user can open. It is off unless the variable is set. The protocol
  is in [BACKENDS.md](BACKENDS.md#4-the-element-channel-for-test-tools).
- **Logging.** `SWIFTUI_GTK_DEBUG=1|2|3` logs clicks, render-tree dumps and updates on GTK; `SWIFTUI_GTK_DARK=1|0`
  overrides the theme's dark preference; `SWIFTUI_DEBUG_RAW=1` logs raw input on WinUI.
- **Test machines.** `Linux/scripts/vm` and `Windows/scripts/vm` drive a Linux or Windows VM from a Mac over SSH
  (sync a checkout, build, run, screenshot, click). `Linux/scripts/create-vm` makes the Linux VM.

## Main API

### Apple's API

The API follows Apple's names and signatures, so most SwiftUI code compiles unchanged. The README's
[supported list](../README.md#whats-here) groups what works today (structure and state, layout, controls, containers
and navigation, presentation, animation, gestures, styling). Two sources show it in use: `Sources/ReferenceApp`, a
large app that compiles unchanged against both frameworks, and the API corpus in `Tools/corpus`, idiomatic code that
must compile against both.

### Additions

These are not Apple API. Each one exists so that code without AppKit or UIKit can do what an Apple app does with
them.

| API | What it does |
|---|---|
| `HostingWindow(title:defaultSize:content:)` | A window that code opens itself, outside the app's scenes (`show()`, `close()`, `onClose`, `isVisible`), on every backend. |
| `Color(light:dark:)` | A color for each appearance, where Apple code would use `Color(nsColor:)` or `Color(uiColor:)`. |
| `TextMeasurer.measure(_:in:)` | Measures a `Text` on one line through the backend (width, height, baseline); nil until a window is up. |
| `Image(_platformData:scale:)` | Decodes PNG, JPEG and other image bytes through the backend; nil before a window is up. |
| `windowMenuBarVisibility(_:)`, `\.windowMenuBar` | Hides the window's own menu bar (Windows, Linux) so the content can draw the menus itself. |
| `\.windowTitleBarArea` (`WindowTitleBarArea`) | Where the window's own controls sit when content runs into the title bar; nil on the Mac. |
| `textEditorLineNumbers(_:)` | A line-number gutter for text editors. GTK draws it; other backends ignore it so far. |
| `onGtkInput(_:)` (Linux), `onWinUIInput(_:)` (Windows) | Raw pointer, wheel and key events over a view, for a remote desktop's picture. |
| `GtkWidgetRepresentable` (Linux) | A GTK widget (`GtkWidget *`) in the hierarchy, GTK's `NSViewRepresentable`. |
| `AppLanguage`, `AppLanguagePicker` (Linux, Windows) | The app's language, from the system or picked in the app (applies from the next launch). |
| `ICULanguagePack` (Linux, Windows) | Downloads ICU format data for a language a release build left out, only after the user agrees. |

Off Apple platforms Foundation's `Locale.current` is always `en_001`. `App.main()` sets the app's locale from
`AppLanguage` before anything runs, and SwiftUI formats dates and numbers and picks translations with it (the
environment's `\.locale` and `\.calendar`). Code that calls Foundation directly (`Date.formatted()`,
`String(localized:)`) still gets `en_001`: read `\.locale` instead.

A release build on Windows can ship ICU with only the app's languages. When the user's language isn't among them,
the app asks once whether to download that language's formats from this repository's GitHub release
`icu-<ICU version>`; nothing is downloaded without a yes. `ICULanguagePack.offer()` asks again (for a Settings
button), `download(_:)` downloads without asking. A pack applies from the next launch.

### Modules that come with `import SwiftUI`

Off Apple platforms `import SwiftUI` also gives these, so code written for Apple platforms finds the same names:

- `Foundation`, `Observation`, and `FoundationNetworking` (`URLSession`) where it is a separate module.
- `Combine`: OpenCombine 0.14.0, vendored as one module named `Combine`, with `ObservableObject`, `@Published`,
  `Timer.publish`, `NotificationCenter` and `URLSession` publishers.
- `UniformTypeIdentifiers` (`UTType`: common system types, app-declared types, extensions and MIME types) and
  `CoreTransferable` (`Transferable` and its representations).
- `CoreGraphics`: geometry, colors, paths, bitmap images and a software-drawn bitmap context.
- [SwiftUIPortability](SwiftUIPortability.md): Foundation API that swift-corelibs-foundation lacks.
- SwiftData's view API (`@Query`, `.modelContainer`, `\.modelContext`), over Apple's SwiftData on macOS and the
  [SwiftData](SwiftData.md) stand-in elsewhere.

The stand-ins among them (`Combine`, `UniformTypeIdentifiers`, `CoreTransferable`, `CoreGraphics`) exist only off
Apple platforms: built for macOS, a module named like an SDK one would shadow it.

## Platform notes

- **macOS** (14+): the AppKit backend is the most complete one. The test suites, including the AppKit tests and the
  parity tests, run here, and the parity data is recorded here against Apple's SwiftUI.
- **iOS and iPadOS**: no backend. Use Apple's SwiftUI.
- **Linux**: GTK 3 backend, tested on Ubuntu 24.04 (Swift 6.3) and 26.04 (Swift 6.4.1) on arm64. v57's apps build
  for it from their `App/` packages. Window chrome is a `GtkHeaderBar` with the toolbar, and the app's commands form
  a menu bar; GTK notes are in [BACKENDS.md](BACKENDS.md#gtk-3-linux--swiftuigtk).
- **Windows**: WinUI 3 backend with a C# host, on Windows 11 arm64 and x64 (Swift 6.4, .NET 10). v57's apps build
  for it from their `App/` packages; Markdown's release build is checked in a Windows VM. Each app keeps its own
  defaults (from the `Info.plist` that `build-app.ps1` stages).
- **Android**: the Kotlin host and backend run this repository's Demo and Gallery apps on an arm64 device. It is
  less exercised than GTK and WinUI. `Image(systemName:)` draws Material Symbols for SF Symbols names on Android,
  Linux and Windows.

## Testing

From the repository root (Swift 6.2+; developed on macOS with Swift 6.4):

```bash
swift test                                        # graph, core, AppKit and parity suites
swift test --filter LayoutIsolationTests          # one suite
PARITY_REPORT=1 swift test --filter ParityTests   # parity counts side by side with Apple's
```

On Linux and Windows `swift test` also builds `CompatTests`, the stand-ins' tests. On Android,
`Android/scripts/swift-android` cross-compiles the tests and `Android/scripts/run-tests-on-device
<path/to/Package.xctest>` runs the bundle on a connected device.

To test an app's own views, host them in [SwiftUIHeadless](SwiftUIHeadless.md)'s `TestHost`.

### Checking parity with Apple's SwiftUI

Body evaluations must match Apple's SwiftUI exactly, and layout work must not exceed it.
[PARITY.md](PARITY.md) explains the harness. In short:

```bash
swift run --package-path AppleSwiftUI parity-recorder   # record Parity/Golden on Apple's SwiftUI (macOS)
swift test --filter ParityTests                         # compare this SwiftUI with the recording
swift run ReferenceApp2                                  # the reference app on this SwiftUI
swift run --package-path AppleSwiftUI ReferenceApp       # the same sources on Apple's SwiftUI
Tools/corpus/check.sh                                    # the API corpus must typecheck against Apple's SwiftUI
```

The corpus also runs as a test (`CorpusRuntimeTests` in the AppKit tests), which hosts every corpus view.
