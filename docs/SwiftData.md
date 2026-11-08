# SwiftData

Off Apple platforms the `SwiftData` product stands in for Apple's SwiftData: `@Model` classes, containers, contexts,
fetches with predicates and sort descriptors. SwiftUI's side (`@Query`, `.modelContainer`, `\.modelContext`) comes
with [`import SwiftUI`](SwiftUI.md). Code that writes `import SwiftData` builds unchanged on Linux, Windows and
Android.

It is meant for the small stores apps keep, such as a sidebar's folders or saved repositories. A container writes
every model's stored properties to one JSON file, loaded whole when it opens. It is not a database: there are no
relationships (`@Relationship` is accepted and ignored), no migrations, no CloudKit sync and no undo.

## Getting started

Add it only for builds off Apple platforms (see [SwiftUI](SwiftUI.md#adding-the-package); the product is only
defined there):

```swift
.package(url: "https://github.com/v57/SwiftUI.git", branch: "main")
// in the target:
.product(name: "SwiftData", package: "SwiftUI")
```

```swift
import SwiftData
import SwiftUI

@Model final class Bookmark {
    @Attribute(.unique) var path: String = ""
    var title: String = ""

    init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

struct BookmarksView: View {
    @Query(sort: \Bookmark.title) private var bookmarks: [Bookmark]

    var body: some View {
        List(bookmarks) { bookmark in
            Text(bookmark.title)
        }
    }
}

@main struct BookmarksApp: App {
    var body: some Scene {
        WindowGroup("Bookmarks") {
            BookmarksView()
        }
        .modelContainer(for: Bookmark.self)
    }
}
```

## Main API

**Models**

- `@Model`: makes a class observable (as `@Observable` does) and persistable. Stored properties must be `Codable`.
  A property with a default value or an optional one may be missing from an older store.
- `@Attribute(.unique)`: inserting a model with the same value replaces the stored one. Other options are accepted.
- `@Transient`: not stored.
- `PersistentModel`: `persistentModelID` (`PersistentIdentifier`), `modelContext`, `isDeleted`, `hasChanges`; models
  are `Identifiable` and `Hashable` by identity.

**Containers and contexts**

- `ModelContainer(for: Bookmark.self, ...)`, `ModelContainer(for: schema, configurations: ...)`: `mainContext`,
  `deleteAllData()`.
- `ModelConfiguration(_ name:schema:isStoredInMemoryOnly:allowsSave:...)` stores `<name>.store` (default
  `default.store`) in the user's Application Support folder, under the app's bundle identifier (or the process name);
  `ModelConfiguration(_ name:schema:url:allowsSave:...)` stores at `url`.
- `Schema([Bookmark.self], version:)`.
- `ModelContext`: `insert(_:)`, `delete(_:)`, `delete(model:where:)`, `fetch(_:)`, `fetchCount(_:)`,
  `fetchIdentifiers(_:)`, `model(for:)`, `registeredModel(for:)`, `save()`, `rollback()`, `transaction(block:)`,
  `hasChanges`, `autosaveEnabled` (on by default: it saves shortly after a change). It posts
  `ModelContext.willSave` and `didSave`.
- `FetchDescriptor(predicate:sortBy:)` with `fetchLimit` and `fetchOffset`; predicates are Foundation's
  `#Predicate`, sorts are `SortDescriptor`s.

**In views** (from `import SwiftUI`)

- `@Query`, `@Query(filter:sort:)`, `@Query(sort:order:)`, `@Query(_ descriptor:)`: the models matching a fetch,
  fetched again when the context changes.
- `.modelContainer(_:)`, `.modelContainer(for:inMemory:...)` on views and scenes; `.modelContext(_:)`;
  `@Environment(\.modelContext)`.

## Platform notes

- **macOS, iOS**: not built; `import SwiftData` is Apple's framework. With this SwiftUI on macOS, `@Query` and
  `.modelContainer` work over Apple's SwiftData.
- **Linux, Windows, Android**: the JSON store above. Each save writes the whole file atomically.

## Testing

`SwiftDataTests` in `CompatTests` (built on Linux and Windows) save, fetch with predicates and sorts, reopen a store
and check that models are observable:

```bash
swift test --filter SwiftDataTests
```

In a test, `ModelConfiguration(isStoredInMemoryOnly: true)` keeps the store out of the file system.
