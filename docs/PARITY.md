# Parity with Apple's SwiftUI

Behaviour and update counts are checked against **real SwiftUI**, not against our expectations.

## How it works

1. `Parity/Scenarios/*.swift` contains scenarios: a root view plus scripted model mutations. The
   directory is symlinked into two targets:
   * `ParityScenariosSwiftUI` — compiled against Apple's SwiftUI,
   * `ParityScenarios` — compiled against this SwiftUI.
   Files just `import SwiftUI`: each target's dependencies decide which framework that is, so
   **the same source** runs on both, unchanged.
2. View code reports work through `Probe`:
   * `let _ = Probe.body("Name")` inside `body` → `body.Name`,
   * `.probeLayout("name")` wraps a view in a transparent `Layout` that counts
     `layout.name.sizeThatFits` / `layout.name.place` (the only way to observe layout inside
     Apple's SwiftUI).
3. `swift run parity-recorder` hosts each scenario in an `NSHostingView` (400×600, offscreen),
   applies each step, pumps the run loop, and writes `Parity/Golden/swiftui-golden.json`.
4. `ParityTests` runs the same scenarios on the headless backend and compares:
   * `body.*` must be **equal** (fewer = a missed update, more = wasted work),
   * `layout.*` must be **≤** SwiftUI's (SwiftUI is allowed to do less layout work).

`PARITY_REPORT=1 swift test --filter ParityTests` prints a side-by-side table.

## Adding a scenario

1. Add views/models and a `ParityScenario` to `Parity/Scenarios/Scenarios.swift`
   (only API both frameworks have; `Layout` methods must stay nonisolated).
2. Add its name to `scenarioNames` in `Tests/ParityTests/ParityTests.swift`.
3. `swift run parity-recorder` (re-record on new macOS releases, commit the JSON).
4. `swift test --filter ParityTests`.

## Findings so far (macOS 27.0.1)

* Body counts of all 11 scenarios match exactly.
* Apple SwiftUI keeps overlay *content* changes inside the overlay (plus one re-placement of the
  primary view), but re-lays out the whole enclosing stack for: background content changes,
  structural changes inside an overlay (`if` in the overlay builder), fixed-frame content changes
  and color-only changes. SwiftUI confines all of these (0 layout events outside).
* `objectWillChange` with an unchanged value (`b = b`) still re-evaluates every observer.

## The reference app

`Sources/ReferenceApp` (`swift run ReferenceApp`) is a large SwiftUI app covering state, observation,
layout, custom layouts, overlays, identity, lists/navigation, forms, environment, animation,
preferences, text, presentations, async and a 1000-row performance lab, with a live body-evaluation
panel. Porting milestone: compile it against SwiftUI (swap the import) and promote each screen's
interactions into parity scenarios.
