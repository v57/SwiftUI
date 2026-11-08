# os

Off Apple platforms the `os` product stands in for the Swift API of Apple's unified logging and its lock: `Logger`,
`OSLog`, `os_log`, `OSSignposter` and `OSAllocatedUnfairLock`. Code that writes `import os` builds unchanged on
Linux, Windows and Android.

Messages go to standard error (and, on Windows, to the debugger through `OutputDebugString`), one line each:
`[subsystem:category] level: message`. There is no log store to query and no Console app. Signposts are accepted and
dropped.

## Getting started

Add it only for builds off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package); the product is only
defined there):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "os", package: "SwiftUI")
```

```swift
import os

let logger = Logger(subsystem: "com.example.myapp", category: "sync")
let count = 3
logger.info("Loaded \(count) items from \("~/Notes", privacy: .private)")

let lock = OSAllocatedUnfairLock(initialState: 0)
lock.withLock { $0 += 1 }
```

## Main API

- `Logger(subsystem:category:)`, `Logger()`, `Logger(_: OSLog)`: `log(_:)`, `log(level:_:)`, `trace`, `debug`,
  `info`, `notice`, `warning`, `error`, `critical`, `fault`.
- `OSLogMessage` interpolation with Apple's options: `privacy:` (`.public`, `.private`, `.sensitive`, `.auto`),
  `format:` for integers and floats, `align:`. The formats and alignment are accepted and not applied.
- `OSLog(subsystem:category:)`, `OSLog.default`, `OSLog.disabled`; `os_log(_:log:_:)` and `os_log(_:log:type:)`.
- `OSSignposter`, `OSSignpostID`: accepted, nothing recorded.
- `OSAllocatedUnfairLock(initialState:)` and `OSAllocatedUnfairLock()`: `withLock`, `withLockUnchecked`, `lock()`,
  `unlock()`.

As on Apple platforms, private values are redacted (`<private>`) in release builds; strings, errors and other
non-numeric values are private unless marked `.public`, numbers and booleans are public. Debug-level messages
(`debug`, `trace`) are dropped in release builds. In a `DEBUG` build everything is written.

## Platform notes

- **macOS, iOS**: not built. Use Apple's `os`.
- **Linux, Android**: standard error.
- **Windows**: standard error and the debugger.

## Testing

`StandInFrameworkTests` in `CompatTests` (built on Linux and Windows) log with interpolation and use the lock:

```bash
swift test --filter StandInFrameworkTests
```
