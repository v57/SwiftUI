# SwiftUIPortability

`SwiftUIPortability` adds the Foundation API that Apple platforms have and swift-corelibs-foundation lacks, so code
written for Apple platforms builds on Linux, Windows and Android: the Trash, the user's well-known folders, file
bookmarks, file coordination, item providers, and a few types SwiftUI's API mentions. It also has two tools for
things Foundation does badly off Apple platforms: `ChildProcess` (Windows, Linux) and `DirectoryWatcher` (Linux).

`import SwiftUI` re-exports it. Libraries that don't import SwiftUI depend on the product directly. On Apple
platforms the module is empty (and the product isn't defined), so code calls the same names there and gets Apple's.

## Getting started

Add it only for builds off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package)):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "SwiftUIPortability", package: "SwiftUI")
```

```swift
import Foundation
#if os(Linux) || os(Windows)
import SwiftUIPortability
#endif

let notes = URL.documentsDirectory.appendingPathComponent("Notes", isDirectory: true)
try FileManager.default.trashItem(at: notes.appendingPathComponent("old.md"), resultingItemURL: nil)

#if os(Linux) || os(Windows)
let git = try ChildProcess(
    executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--version"], directory: notes,
    environment: ProcessInfo.processInfo.environment)
git.read(.output) { chunk in print(String(decoding: chunk, as: UTF8.self)) }   // blocks until the output ends
let status = git.waitUntilExit()
#endif
```

## Main API

**Foundation additions** (off Apple platforms; Apple's own API on Apple platforms)

- `FileManager.trashItem(at:resultingItemURL:)`: the Recycle Bin on Windows, the freedesktop.org trash
  (`$XDG_DATA_HOME/Trash`, by default `~/.local/share/Trash`) elsewhere.
- `URL.documentsDirectory`, `applicationSupportDirectory`, `cachesDirectory`, `downloadsDirectory`,
  `desktopDirectory`, `moviesDirectory`, `musicDirectory`, `picturesDirectory`, `libraryDirectory`.
- `URL.bookmarkData(options:includingResourceValuesForKeys:relativeTo:)` and
  `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`: a bookmark is the file's path (there is no
  sandbox to carry access across launches), so a moved file is not found.
- `URL.startAccessingSecurityScopedResource()` (always true) and `stopAccessingSecurityScopedResource()`.
- `NSString.abbreviatingWithTildeInPath`.
- `NSFileCoordinator` and `NSFilePresenter`: reads and writes run at once (no other process coordinates), and
  presenters hear about changes from a watcher that compares the item's files once a second.
- `FileManager.ubiquityIdentityToken` and `url(forUbiquityContainerIdentifier:)`: always nil (no iCloud).
- `NSItemProvider` (with `register(_:)` and `loadTransferable(type:completionHandler:)` for `Transferable` types),
  `NSUserActivity`, `FileWrapper`, `InlinePresentationIntent` and the `inlinePresentationIntent` attributed-string
  key (Markdown attributed strings).
- `setenv` and `unsetenv` on Windows, whose C runtime lacks them.

**ChildProcess** (Windows, Linux)

A child process that inherits only its own standard handles. Foundation's `Process` there lets every child inherit
the app's inheritable handles, so one child can keep another's pipe open; on Linux it also learns of an exit only
once every holder of the child's descriptors is gone.

- `ChildProcess(executable:arguments:directory:environment:input:verbatimArguments:)`: `environment` replaces the
  app's; with `input` the child's standard input is a pipe, else the null device. On Windows arguments are quoted the
  way the C runtime splits them, and `verbatimArguments` passes them as they are (`cmd /s /c "..."`). On Linux the
  child runs in a process group of its own.
- `read(_:chunk:)` (`.output` or `.error`, blocking until the child closes the stream: call it on its own thread),
  `write(_:)`, `closeInput()`, `waitUntilExit()` (128 + the signal's number when a signal ended it on Linux),
  `terminate()` (the whole process group on Linux), `processIdentifier`.

**DirectoryWatcher** (Linux)

Watches folder trees with inotify, as FSEvents streams do on macOS.

- `DirectoryWatcher(paths:fileEvents:latency:queue:handler:)`: nil when inotify can't be used. Adds every folder
  below the roots and each folder made or moved in later (symbolic links aren't followed), and hands the changes
  gathered over `latency` seconds to `handler` on `queue`.
- `Change`: `path`, `structural` (created, removed or renamed), `rescan` (events were dropped; everything under
  `path` may have changed).
- `stop()`: no handler call is scheduled after it returns.

## Platform notes

- **macOS, iOS**: the module is empty and the product isn't defined.
- **Linux**: everything above.
- **Windows**: everything but `DirectoryWatcher`.
- **Android**: the Foundation additions; no `ChildProcess` or `DirectoryWatcher`.

## Testing

`CompatTests` (built on Linux and Windows) cover `ChildProcess` (exit codes, input, children side by side,
terminating a group on Linux; argument quoting on Windows) and `DirectoryWatcher`:

```bash
swift test --filter ChildProcessTests
swift test --filter DirectoryWatcherTests
```
