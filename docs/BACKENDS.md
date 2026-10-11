# Writing a backend (GTK, WinUI, Android, …)

A backend is a module that depends on `_SwiftUICore` and provides three things.

## 1. `RenderBackend` + `PlatformServices`

```swift
@MainActor public protocol RenderBackend: PlatformServices {
    var rootHandle: AnyObject { get }                       // the host widget
    func makeView(for node: RenderNode) -> AnyObject        // configure with node.content/frame/actions
    func updateContent(of view: AnyObject, node: RenderNode)
    func setFrame(of view: AnyObject, node: RenderNode)     // frame relative to platform parent, top-left origin
    func setChildren(of view: AnyObject, node: RenderNode, to children: [AnyObject]) // z-order, bottom first
}

@MainActor public protocol PlatformServices: AnyObject {
    func measureText(_ text: ResolvedText, proposal: ProposedViewSize) -> CGSize
    func firstBaseline(of text: ResolvedText) -> CGFloat
    func imageSize(_ image: ResolvedImage) -> CGSize
    func controlMetrics(_ control: ControlKind) -> ControlMetrics
}
```

Rules:

* Use **absolute positioning inside a fixed container** (frames are computed by SwiftUI layout).
  GTK: `GtkFixed` (or a custom `GtkWidget` with `size_allocate`); WinUI: `Canvas`; Android: a
  custom `ViewGroup` whose `onLayout` applies the frames.
* Measure and draw text with the same engine/attributes (Pango / DirectWrite / `StaticLayout`),
  otherwise layout and rendering disagree.
* Platform events call `node.actions.primary/setBool/setText/setDouble` on the main thread.
* `setChildren` may receive the same list; make it cheap when unchanged.
* A `.scrollView` node's children belong in the scrollable document/content widget.

`SwiftUIHeadless/HeadlessBackend.swift` (≈150 lines) is the smallest complete reference;
`SwiftUIAppKit` is the production one.

## 2. A host

Own a `ViewGraph`, forward size changes with `setProposedSize`, set `colorScheme` and other
platform environment with `setEnvironment`, and call `update()` once per main-loop iteration when
`onNeedsUpdate` fires:

* GTK: `g_idle_add` (priority `G_PRIORITY_HIGH_IDLE + 10`, before redraw) or a frame clock
  `before-paint` handler.
* WinUI: `DispatcherQueue.TryEnqueue` or `CompositionTarget.Rendering`.
* Android: `Choreographer.postFrameCallback`.

See `SwiftUIAppKit/HostingView.swift` (`GraphHostingView`).

## 3. An app runner

Set `AppRuntime.runner` to a function that opens one platform window per `WindowDescription`
(each with a host) and runs the main loop, then add the platform branch to
`Sources/SwiftUI/SwiftUI.swift` so `@main struct MyApp: App` works unchanged.

## Platform notes

* **Combine**: on Linux/Windows/Android the package's `Combine` stand-in (vendored OpenCombine,
  `Sources/Combine`) provides it, so app code keeps `import Combine`. Without any Combine module,
  `_SwiftUICore` compiles `State/CombineShim.swift` instead (`ObservableObject`, `@Published`,
  `AnyCancellable`). On macOS you can check the shim builds with
  `swift build --scratch-path .build/shim -Xswiftc -DSWIFTUI_COMBINE_SHIM --target _SwiftUICore` (only the
  core: AppKit brings in the real Combine, which makes `ObservableObject` ambiguous in SwiftUIAppKit).
* **CoreGraphics types**: `CGFloat/CGSize/CGPoint/CGRect` come from Foundation on non-Apple
  platforms; sources import `CoreGraphics` conditionally.
* **Observation** ships with the Swift toolchain on all platforms.
* **Android**: never test on an emulator (see the user's global instructions) — use a device over
  adb. The backend talks to Android views through JNI (e.g. swift-java); keep the `RenderNode`
  → `android.view.View` mapping on the UI thread.

## GTK 3 (Linux) — `SwiftUIGtk`

* One `GtkDrawingArea` per window paints a retained `GtkNode` tree with cairo; Pango lays out
  and measures text with the same layouts. Controls are drawn with the theme's renderers
  (`gtk_render_*` on style contexts for CSS node paths such as `scale trough slider`).
* Text fields are drawn on the canvas and become a native `GtkEntry`/`GtkTextView` (in a
  `GtkFixed` overlay) only while edited, so native widgets never cover SwiftUI presentations.
* Hit testing follows the AppKit backend: text without links, colors, shapes and images are
  click-through; buttons/controls and pointer-handling effects own their frame.
* GTK owns the main loop: the main dispatch queue is drained from libdispatch's eventfd and
  `RunLoop.main` timers are armed as GLib timeouts (`GtkMainLoop`).
* `SWIFTUI_GTK_DEBUG=1|2|3` logs clicks / render-tree dumps / content updates and frames.
* Test VM: `Linux/scripts/create-vm <ubuntu-desktop-arm64.iso>` (UTM bundle, unattended
  install); `Linux/scripts/vm run GalleryGtk`, `vm shot GalleryGtk out.png`, `vm click x y`.
