# SwiftUI architecture

SwiftUI re-implements SwiftUI in Swift for AppKit, GTK, WinUI and Android. The goal is to be
**source compatible** with SwiftUI and **behaviourally equivalent**, including how much work an
update does: body evaluations must match SwiftUI exactly, and layout/render work must be equal or
less. Both claims are verified against Apple's SwiftUI by the parity harness (`docs/PARITY.md`).

```
┌──────────────────────────── App code (import SwiftUI) ───────────────────────────┐
│  View / ViewModifier / Layout / @State / @Observable / ObservableObject / App      │
└────────────────────────────────────────────────────────────────────────────────────┘
┌─ _SwiftUICore ─────────────────────────────────────────────────────────────────────┐
│  _makeView / _makeViewList  ─►  view graph (attributes in subgraphs)                │
│  body attributes · dynamic properties · view lists & containers · layout computers │
│  geometry attributes · render sinks ─► render tree (RenderNode) ─► Renderer.commit │
└────────────────────────────────────────────────────────────────────────────────────┘
┌─ SwiftUIGraph ───────────┐   ┌─ backends (RenderBackend + PlatformServices) ───────┐
│ Attribute, Subgraph,      │   │ SwiftUIAppKit  · SwiftUIHeadless (tests)          │
│ push-dirty / pull / cutoff│   │ SwiftUIGtk · SwiftUIWinUI · SwiftUIAndroid        │
└───────────────────────────┘   └──────────────────────────────────────────────────────┘
```

## 1. The attribute graph (`Sources/SwiftUIGraph`)

Everything that can change is an `Attribute<Value>`:

* **Source attributes** hold values set from outside (`@State` storage, the root view, the
  proposed window size, the root environment).
* **Computed attributes** run a rule closure. Every attribute read during the rule is recorded as
  an input, so dependencies are exact and dynamic.

Update algorithm — *push dirty, pull recompute, cut off on equality*:

1. `setValue` / `invalidate()` flips a `dirty` bit on all transitive dependents (no evaluation).
   Dirty **eager** attributes (render sinks, dynamic list containers, onChange observers) are put
   into a priority queue ordered by view depth.
2. `AttributeGraph.update()` pulls eager attributes parent-first. Pulling a dirty attribute first
   brings its inputs up to date; **if no input actually changed, its rule does not run**.
3. If a rule runs and produces a value equal to the previous one (`isEqual`), the revision is not
   bumped and dependents downstream are not recomputed. The *old* value is kept (so e.g. a layout
   computer keeps its size cache).

Value equality uses `GraphComparison` (equivalent to SwiftUI's `compareValues`): POD types are
compared bitwise, `Equatable` types with `==`, structs/tuples field-by-field (runtime field offsets
via the reflection runtime entry points), classes by identity, closures by (function, context)
pointer. Types may opt into custom rules via `_GraphComparable` (`State`, `Environment`,
`StateObject` are always "identical"; `Binding` compares locations).

`Subgraph` scopes lifetime: every view identity (an `if` branch, a `ForEach` element, `AnyView`
content, `.id()` content, a container child) owns one. Destroying it destroys its attributes,
runs cleanups (render-node removal, `onDisappear`, subscriptions) and its child subgraphs.

## 2. The view graph (`Sources/_SwiftUICore/Core`)

### Building

Like SwiftUI, the graph is built from **types**, once per identity, via two static entry points:

* `static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs` — unary context.
* `static func _makeViewList(view:inputs:) -> _ViewListOutputs` — list context (stack children).

`_GraphValue<V>` is the view value as an attribute; children get **projection attributes**
(`view.project { $0.content }`) with structural equality cut-off. View values themselves are never
stored outside attributes.

* **Composite views** (`body` is a view): `makeBodyAttribute` creates one attribute whose rule reads
  the view value, installs dynamic properties, and evaluates `body` inside
  `withObservationTracking`. Body re-runs only if (a) the view value changed field-wise, (b) a
  `@State`/`@Environment` it *read* changed, (c) an `@Observable` property it read changed, or
  (d) an `ObservableObject` it observes sent `objectWillChange`.
* **Primitive views** (`Body == Never`) implement `_makeView` themselves: they create a layout
  attribute and, if they draw, a platform render node.

`_ViewInputs` carries: host, subgraph, environment attribute, **geometry attribute assigned by the
parent**, render parent + coordinate origin, depth (for eager ordering), path (diagnostics),
enclosing stack axis (for `Spacer`/`Divider`), and the custom-modifier content stack.
`_ViewOutputs` carries the view's **layout attribute** (`LayoutComputer`).

### View lists and identity

`ViewList` is a tree of `element` (a factory for one unary view), `nested` (static sub-list with an
identity component) and `dynamic` (an attribute producing a sub-list). `TupleView` contributes
`[index]` components, `ForEach` `#id`, conditionals `?branch`, `.id()`/`AnyView` explicit keys.
Composite views are flattened (their `@State` lives at list level, keyed by the element identity),
modifiers wrap each element (like SwiftUI).

`ViewListContainer` (owned by stacks/layout containers) flattens the list in an eager attribute,
diffs identities, creates a child subgraph for new identities and destroys removed ones. Existing
children are untouched by insertions/removals/moves — only their geometry may change.

### Dynamic properties

`DynamicPropertyBuffer` finds dynamic-property fields by reflected field offsets (once per type)
and, before each body evaluation, installs them in place into a copy of the view value: `@State`
binds to its source attribute, `@Environment` to a per-property projection attribute (so a view
only depends on the keys it reads), `@ObservedObject`/`@StateObject`/`@EnvironmentObject`
subscribe `objectWillChange` to the body attribute, user `DynamicProperty` structs are recursed
into and then `update()`d.

### Observation

* `@Observable`: body (and `ForEach` row closures, `GeometryReader` content) run inside
  `withObservationTracking`; `onChange` invalidates exactly that attribute → only views that read
  the changed property re-run.
* `ObservableObject`: `objectWillChange` invalidates every observing body (SwiftUI semantics).
  On platforms without Combine, `State/CombineShim.swift` provides `ObservableObject`,
  `@Published`, `AnyCancellable`.

## 3. Layout (`Sources/_SwiftUICore/Layout`)

Two attribute kinds per view:

* **Layout attribute** → `LayoutComputer`: answers `sizeThatFits(proposal)` (cached per proposal
  inside the computer instance), explicit alignment guides, spacing, layout priority, layout
  values. Containers build `LayoutEngineComputer<L: Layout>` from their children's computers; the
  built-in stacks are ordinary `Layout`s (`_VStackLayout`, …), exactly like SwiftUI.
* **Geometry attribute** (`ViewGeometry`: origin, size, proposal), *assigned by the parent*: a
  container's `placements` attribute runs `placeSubviews` and each child's geometry is a projection
  of it with equality cut-off.

`LayoutComputer.isEquivalent(to:)` decides whether replacing a view's computer is visible to its
parent. This is how **layout boundaries** are expressed:

| View | Boundary because |
|------|------------------|
| `.overlay` / `.background` | The modifier forwards the *primary* view's layout attribute unchanged. The secondary content's geometry depends on the primary's size — never the reverse. |
| `.frame(width:height:)` with both fixed | Size cannot depend on the child. |
| `GeometryReader`, `.position` | Take the proposal regardless of content. |
| `ScrollView` | Flexible along its axes; content only affects the content geometry. |
| `.offset` | Changes the child's geometry only. |
| `Text` color/style change | Equivalent when string, font and line limit are equal. |

So a change inside an overlay recomputes: the overlay content's body/layout → the secondary
geometry rule → the secondary content's render sinks. Nothing outside the modifier is even marked
dirty. `LayoutIsolationTests` and the `overlay-isolation` parity scenario assert this (Apple's
SwiftUI does the same for overlay content, but relayouts the whole stack for background content,
structural overlay changes and color changes; SwiftUI confines all of these).

## 4. Rendering (`Sources/_SwiftUICore/Render`)

* A primitive that draws creates a `RenderNode` (`platform` kind) plus an eager **sink attribute**
  computing `RenderSnapshot(frame relative to platform parent, RenderContent)`. The sink only fires
  when the snapshot changes.
* Layout-only structure (stacks, modifiers, list items) creates `group` render nodes, which keep
  z-order without platform views; they are flattened when syncing a platform container's children.
* Container-like primitives (`Button` bezel, `ScrollView`, effects such as opacity/clip/tap) are
  platform nodes with children; children's frames are relative to them.
* `Renderer.commit()` runs after the graph settled: creates views for new nodes (top-down), syncs
  child lists of changed containers, then applies content and frame changes. Each operation is
  counted in `UpdateTracer`. A container's child list goes to the backend as the changed range only
  (`replaceChildren`), and a commit or animation frame is one batch for the backend
  (`willCommit`/`didCommit`: on AppKit one Core Animation transaction).
* **Item spaces.** Each item of a lazy stack, and of a stack with 16 or more children, starts its own
  geometry space: a container node (`.effect(.group)`) at the item's placement, the item laid out
  from origin zero inside it (coordinate spaces, `spaceOrigin` and the scroll viewport translate).
  When a view above grows or is built, the items below move as a whole; nothing inside them is
  placed or framed again. The container gets a platform view only while it holds views (a lazy
  item's placeholder costs the backend nothing), and transitions/matched geometry of the view just
  inside it apply to it.
* **Hover** (`HoverTracker`, for every backend): hosts report the pointer; hover regions (nodes with
  hover actions, indexed by the renderer) are hit-tested only once the pointer has rested and nothing
  has scrolled for 0.1 s, or at once on a click. Hovered views follow the pointer and leave as soon
  as it leaves them. AppKit hosts use one tracking area.

`RenderContent` is a closed, platform-independent enum (`text`, `color`, `shape`, `image`,
`button`, `toggle`, `textField`, `slider`, `scrollView`, `effect`). Event handlers live in
`RenderActions` and read the latest view value when they fire.

## 5. Update cycle

```
event / async mutation ─► source.setValue / attribute.invalidate()  (dirty bits, enqueue eager)
                       ─► ViewGraph.onNeedsUpdate ─► host schedules one update per run-loop turn
ViewGraph.update():
   repeat
     graph.update()      pull eager attributes parent-first (containers, sinks, onChange)
     renderer.commit()   apply platform changes in one batch
     run deferred actions (onAppear/onDisappear/onChange/task start)
   until nothing pending
```

AppKit schedules via a `CFRunLoopObserver` (before-waiting, common modes) — one transaction per
run-loop turn, like SwiftUI/Core Animation. Resizes lay out synchronously.

## 6. Animation

* **Transactions.** Every source change records `Transaction.current` (set by `withAnimation`,
  `Binding.animation`, `.transaction`). An update pass runs with the merged transaction;
  `.animation(_:value:)` and `.transaction {}` create `AnimationScope`s resolved per render node.
* **Render interpolation.** Layout runs once, at the final state. The renderer keeps *presented*
  vs *target* frame/content per node and interpolates frames, colors, opacity/transform effects and
  shadows on each display frame (`ViewGraph.renderAnimationFrame()`, driven by the host's display
  link or a manual clock in tests). Shape paths are built for their target size and scaled by the
  backend to the animating frame.
* **`Animatable`.** Views/shapes with `animatableData` get an animator attribute that interpolates
  the data and re-runs body per frame (exactly SwiftUI's behaviour).
* **Transitions.** Inserted platform views animate from the transition's active state; removed
  ones stay as "ghosts" until their removal transition ends. `matchedGeometryEffect` moves the
  inserted view from its removed partner's frame.

## 7. Presentations, preferences, traits

* Sheets/alerts/dialogs/popovers/menus register in a per-host `PresentationRegistry` and render in
  a separate presentation tree above the root (pure SwiftUI views, backend-independent).
* Preferences are outputs: only keys some ancestor requested are produced and combined.
* View traits (`.tag`, `.zIndex`, `.tabItem`, grid cell spans, row backgrounds) ride on list
  elements; Picker/List/TabView/Grid read them.

## 8. Lazy stacks

Inside a `ScrollView`, `LazyVStack`/`LazyHStack`/`List` instantiate only elements intersecting the
viewport (a source attribute updated from backend scroll events), using measured sizes and an
average-size estimate for the rest — matching Apple SwiftUI's row counts (`lazy-list` parity
scenario). `ScrollViewReader` resolves ids through the scroll view's `ScrollTargets`.

Scrolling is O(visible): offsets, the stack's length and the visible range come from prefix sums
(Fenwick trees) of measured sizes and gaps plus the estimate for the rest, the flattened list is kept
in its own attribute (it changes with the list, not the viewport), and rows are items with their own
space (§4). `ScalingTests` asserts the work per scroll step is the same for 1,000 and 100,000 rows.
The scroll view owns its offset: the graph only sends explicit requests (`scrollTo`), each applied
once.

## 9. Backends

A backend implements `RenderBackend` (create/update/frame/children of platform views) and
`PlatformServices` (text/image measurement, control metrics). See `docs/BACKENDS.md`.

## 10. Diagnostics

`UpdateTracer` records `body`, `sizeThatFits`, `placement`, `geometry`, `listUpdate`,
`renderInsert/Remove/Content/Frame` events with the view path (e.g.
`OverlayScreen/VStack/[1]/@overlay/Badge/Text`). Tests assert on it; it can be disabled with
`tracer.isRecording = false`.

## 11. Concurrency

Graph and view-building types are `@MainActor`. `View`, `ViewModifier`, `DynamicProperty`,
`Layout`, `App`, `Scene` are `@MainActor @preconcurrency`. Value types (`Color`, `Font`, geometry)
are nonisolated and `Sendable`. Note: Apple's `Layout` methods are *nonisolated*; code shared with
Apple SwiftUI must not call main-actor API from `Layout` methods.
