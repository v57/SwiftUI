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
SwiftData, ShareLink, ...).

## Docs

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
