# SQLite3

Off Apple platforms the `SQLite3` product stands in for Apple's `SQLite3` module: the SQLite C API, so code that
writes `import SQLite3` builds unchanged on Linux, Windows and Android. It is the plain C API, not a Swift wrapper.

## Getting started

Add it only for builds off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package); the product is only
defined there):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "SQLite3", package: "SwiftUI")
```

```swift
import SQLite3

var db: OpaquePointer?
guard sqlite3_open(":memory:", &db) == SQLITE_OK else { fatalError("can't open") }
defer { sqlite3_close(db) }
sqlite3_exec(db, "CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (41), (1);", nil, nil, nil)

var statement: OpaquePointer?
sqlite3_prepare_v2(db, "SELECT SUM(v) FROM t", -1, &statement, nil)
defer { sqlite3_finalize(statement) }
if sqlite3_step(statement) == SQLITE_ROW {
    print(sqlite3_column_int(statement, 0))   // 42
}
```

## Main API

SQLite's C API (`sqlite3_open`, `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_column_*`, ...), as in SQLite's own
documentation.

## Platform notes

- **macOS, iOS**: not built. Use the SDK's `SQLite3`.
- **Linux**: the system's SQLite (`libsqlite3-dev` to build). It is built with column metadata, as Apple's is, so
  `sqlite3_column_table_name` and friends answer.
- **Windows, Android**: the Swift toolchain's SQLite (swift-toolchain-sqlite). It has no column metadata:
  `sqlite3_column_table_name`, `sqlite3_column_database_name` and `sqlite3_column_origin_name` always return nil.

## Testing

`StandInFrameworkTests` in `CompatTests` (built on Linux and Windows) run a query:

```bash
swift test --filter StandInFrameworkTests
```
