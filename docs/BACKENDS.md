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

## 4. The element channel (for test tools)

Run an app with `SWIFTUI_INSPECT=1` and it answers on a local endpoint named after its process:
`$XDG_RUNTIME_DIR/swiftui-inspect-<pid>` (a Unix socket, mode 0600) on Linux, the named pipe
`\\.\pipe\swiftui-inspect-<pid>` (this user only) on Windows. Send `elements` and a newline; the answer is one
line of JSON, `{"windows": [{"title", "id", "width", "height", "scale", "elements": [{"role", "label", "value",
"x", "y", "width", "height", "depth", "enabled"}]}]}`. Frames are the window's pixels from the top-left of what
shows of it (no GTK shadow, no invisible resize borders), as a capture of the window shows them; `id` is the X
window id or the HWND. Roles and labels come from `_Inspection.decide` (`_SwiftUICore/Render/Inspection.swift`),
as a screen reader names things: the accessibility label first, else a control's own text, a field's placeholder
or a symbol's name; a field without a placeholder goes by the text on its left (a form row); buttons and toggles
speak for their labels; secure fields give no value; the title bar's back and toolbar buttons are listed too. Remote's Linux and
Windows hosts read it for `elements`, `click "Save"` and `waitfor`, and Remote's `launch` sets the variable. Off
by default: nothing is opened unless the person running the app asks for it. GTK serves it in `GtkInspect`; on
WinUI Swift lists the elements by node id (`swiftui_inspect`) and the C# host places them (`HostView.WriteElements`,
`Inspector`), since XAML knows where each node ended up (scrolling, transforms, the title bar).

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
  A `TextEditor` on the canvas (`GtkTextArea`) keeps its text laid out once and draws only the visible lines
  from its own scroll offset (the wheel scrolls it unfocused); a click places the caret where it lands and the
  text view takes over at the same offset (transparent, the canvas drawing text and caret, until GTK has laid
  out the lines above). The selection binding (`TextEditor(text:selection:)`, for an `AttributedString` too) goes
  both ways, and `textEditorLineNumbers(.visible)` (not Apple API) adds a line-number gutter, on the canvas
  and in the text view's left border window, from each one's line geometry. An edit retags only the
  foreground runs that changed.
* Hit testing follows the AppKit backend: text without links, colors, shapes and images are
  click-through; buttons/controls and pointer-handling effects own their frame.
* GTK owns the main loop: the main dispatch queue is drained from libdispatch's eventfd and
  `RunLoop.main` timers are armed as GLib timeouts (`GtkMainLoop`).
* `SWIFTUI_GTK_DEBUG=1|2|3` logs clicks / render-tree dumps / content updates and frames.
* Raw input (not Apple API): `onGtkInput { (event: GtkInputEvent) -> Bool }` gives a view every button's press
  and release (with click counts), pointer motion, the wheel and, while it has focus (pressed last), keys with
  their keysyms and hardware codes; core's `_onPlatformInput` carries it (`RenderActions.platformInput`). Remote's
  picture uses it on Linux. WinUI has the same as `onWinUIInput { (event: WinUIInputEvent) -> Bool }` (buttons
  with click counts, motion, the wheel with precise touchpad deltas, virtual keys, characters and focus loss; the
  host's effect node takes raw input with flag 32 and calls the `swiftui_raw_input` export; `SWIFTUI_DEBUG_RAW=1`
  logs it), and an image whose pixels are already BGRA (`CGImage._withBGRABytes`) goes to the WinUI host as raw
  pixels (`pixel_image` callback, a `WriteableBitmap`) instead of a PNG, for pictures redrawn every frame.
* Test VM: `Linux/scripts/create-vm <ubuntu-desktop-arm64.iso>` (UTM bundle, unattended
  install); `Linux/scripts/vm run GalleryGtk`, `vm shot GalleryGtk out.png`, `vm click x y`.
* Window chrome: a `GtkHeaderBar` holds the title and toolbar items; content that runs up into the
  title bar (`.windowStyle(.hiddenTitleBar)`, `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`)
  swaps it for an empty title bar and floats the header bar's buttons over the content's top-right
  corner (`windowTitleBarArea` tells the content where they are; presses nothing takes in that row
  drag the window). The app's commands (`WindowMenu.standardMenus`, shared with WinUI) form a
  `GtkMenuBar` with Ctrl shortcuts; content that draws its own menus (`windowMenuBar`) hides it.
* `preferredColorScheme` sets GTK's `gtk-application-prefer-dark-theme` (the newest window that
  asks wins); `SWIFTUI_GTK_DARK=1|0` overrides the theme's preference at launch.

### Script mode

`<app> --script <file>` (or `SWIFTUI_SCRIPT=<file>`) runs a script against the app, as the WinUI
host's `--script`: one command per line, `#` comments, coordinates in points from the window's top
left (header bar included, as screenshots show it). It works under Xvfb (`xvfb-run -a <app> --script
...`), since screenshots are drawn by GTK rather than read from the screen.

| Command | |
|---|---|
| `wait <ms>` | wait |
| `waitfor <text> [ms]` | wait until a text shows (default 5 s; a failure counts) |
| `screenshot <png>` | the window as GTK draws it (after the next frame) |
| `screen <png>` | the whole X screen (popups, dialogs) |
| `dump <txt> [all]` | window, header buttons, menus and render tree with frames; `all` keeps hidden views |
| `tap <text>` | click a text, placeholder, field text, form row label or `image:<symbol>`; else a header button by label or tooltip |
| `tapat x y` / `click x y`, `rclick x y`, `hover x y`, `scroll x y dy [dx]` | pointer input at a point |
| `type <text>` | type into the focused field (or the first one) |
| `fill <field>\|<text>` | focus a field (placeholder, text, `#n` or form label) and type |
| `keys <text>` | key presses through GTK (`\n`, `\t`, `\e`) |
| `key <combo>` | e.g. `ctrl+w`, `ctrl+shift+k`, `Escape` (GDK key names) |
| `menu <Menu/Item>` | run a menu bar item |
| `back` | the header bar's back button |
| `window <n\|title>`, `windows`, `resize w h` | pick, list and size windows |
| `expect <text>` | like `waitfor` without waiting |
| `log <text>`, `exit` | report; quit (status 1 when an expectation failed) |

Smoke scripts live in `Linux/tests` (`gallery.script`, `presentations.script`, `component.script`).

### Apps on Linux

A v57 app is a package of its own in its repository's `App/` folder (`App/Package.swift`, beside the libraries'
package at the root; Get is the model): the `<App>App` library holds the app's code on every platform, and
`App/Sources/<App>/<App>Main.swift` is the `@main` entry point. The Xcode project at the root builds that file into
the Apple bundle; on Linux the package builds it as an **executable product named after the app**, like the Windows
`<App>WinUI` library (the same settings; Linux needs no host):

```swift
#elseif os(Linux)
package.targets.append(
  .executableTarget(
    name: "<App>", dependencies: ["<App>App", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: [/* as the Windows target, including the -import-module flags */]))
package.products.append(.executable(name: "<App>", targets: ["<App>"]))
#endif
```

Build and run it in place (in `App/`: `V57_LOCAL=1 swift build --product <App>` against the sibling checkouts) or
stage it with `Linux/scripts/build-app --package <repo>/App <App>`: `.build/linux/<App>/` gets the
executable, its resource bundles, the Material Symbols font, an `Info.plist` (bundle identifier and
version from the Xcode project at the repository's root, so `UserDefaults` are the app's own) and a `.desktop` file
(`--install` adds it to the user's applications, `--static` links the Swift runtime in, `--run` and
`--script <file>` run it, under Xvfb when there is no display).
