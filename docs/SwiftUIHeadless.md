# SwiftUIHeadless

`SwiftUIHeadless` hosts views in memory, without a window or a platform toolkit, so tests can build a view, tap its
buttons, type into its fields and read what it shows. Updates run only when the test asks for them, and text has
fixed metrics (0.5 × the point size per character, 1.2 × the point size per line), so the results are the same on
every machine and platform. This package's own core and parity tests run on it.

It is not a renderer: nothing is drawn, and each rendered view is a `HeadlessView` with a frame and its content. It
hosts views of this SwiftUI only, so a test target that uses it builds against this package, not Apple's
SwiftUI (see [SwiftUI](SwiftUI.md#adding-the-package)).

## Getting started

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
```

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyAppUI",
        .product(name: "SwiftUI", package: "SwiftUI"),
        .product(name: "SwiftUIHeadless", package: "SwiftUI"),
    ]
)
```

```swift
import SwiftUI
import SwiftUIHeadless
import Testing

struct Counter: View {
    @State private var count = 0

    var body: some View {
        VStack {
            Text("Count: \(count)")
            Button("Increment") { count += 1 }
        }
    }
}

@MainActor
@Test func incrementShowsTheNewCount() {
    let host = TestHost(Counter())
    host.tap("Increment")
    #expect(host.texts.contains("Count: 1"))
}
```

`TestHost` builds and updates the view once when it is made. Each interaction runs its handler and then one update,
as an event and a run-loop turn would in an app.

## Main API

`TestHost` is `@MainActor`.

**Hosting**

- `TestHost(_ root:size:)`: hosts a view in a 400 × 600 point window (or `size`).
- `TestHost(size:graph:)`: hosts a graph built by a factory, such as a scene's window.
- `flush()`: runs one update transaction. `needsFlush` says whether something changed since the last one.
- `resize(to:)`: proposes a new window size.

**Reading what shows**

- `texts`: every text shown, window content first, then the toolbar.
- `view(withText:)`, `views(withText:)`: the `HeadlessView`s showing a text.
- `allViews`, `root`: the hosted views. A `HeadlessView` has its `frame`, `text`, `children`, `content` and
  `accessibility` properties, and counts of its content and frame updates.
- `dump()`: the view tree as text, for a failing test's message.

**Interacting**

- `tap(_:)`: taps the innermost button or tap target containing the text.
- `type(_:intoFieldAt:)`, `setToggle(at:to:)`: edits the `index`th text field or toggle.
- `drag(_:by:steps:)`, `secondaryClick(_:)` (context menus), `pressEscape()` (dismisses the top presentation).
- `scroll(to:scrollViewAt:)`, `scroll(by:frames:scrollViewAt:)`: scrolls a scroll view at once or over frames.
- `movePointer(to:)`, `pressPointer(at:)`, `pointerExited()`: hover.

**Time and animation**

- `advance(by:)`: moves the manual clock and renders one animation frame.
- `finishAnimations(limit:)`: runs frames at 60 Hz until every animation ended.
- `wait(_:)`: moves the clock in small steps, so hover wake-ups fire.

**Counting work**

- `tracer` (`UpdateTracer`): the updates the graph made, as events (`body`, `sizeThatFits`, `placement`,
  `geometry`, `listUpdate`, render inserts, removals, content and frame changes) with each view's path.
  `tracer.count(.body)` counts body evaluations; `resetTrace()` clears the events.

## Platform notes

Pure Swift on top of the core, so it builds wherever the core does: macOS, Linux, Windows and Android. It doesn't
depend on the platform backend; a test that imports `SwiftUI` still links the backend for its platform.

## Testing

The package's own suites use it: `swift test --filter SwiftUICoreTests` (behaviour, layout isolation, presentations,
animations) and `swift test --filter ParityTests` (update counts compared with Apple's SwiftUI, see
[PARITY.md](PARITY.md)). `Tests/SwiftUICoreTests` is the best source of examples.
