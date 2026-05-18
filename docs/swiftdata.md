# SwiftData best practices

Reference for SwiftData under iOS 17+ with strict concurrency. Models in this codebase live in `Kios/Models/`; the container factory is `Kios/App/ModelContainerFactory.swift`.

The hard rules are in `Kios/Models/CONVENTIONS.md`. This doc adds the **why**, the patterns, and the pitfalls.

## Model class

Use `@Model` on a `final class`. Stored properties are tracked automatically.

```swift
// Kios/Models/Book.swift
@Model
final class Book {
    @Attribute(.unique) var id: UUID

    var source: Source                  // implicit to-one relationship
    var title: String
    var authors: [String]
    var format: BookFormat              // Codable enum — stored inline
    var filename: String?
    var addedAt: Date
    var furthestLinearPosition: Int = 0

    init(...) { ... }
}
```

Rules:

- `final` is required — `@Model` doesn't support inheritance.
- Plain types (`String`, `Int`, `Date`, `UUID`, `URL`, `Bool`, `Data`, `[String]`) are stored inline.
- `Codable` enums and value types are stored inline (Book.format above).
- Other `@Model` classes are stored as relationships (Book.source above).
- Optional vs non-optional matters: `String?` ≠ `String` at the schema level.

### Attributes

| Attribute | Use |
|-----------|-----|
| `@Attribute(.unique)` | Enforces uniqueness; lets the store upsert on conflict. |
| `@Attribute(.externalStorage)` | Store large `Data` blobs out-of-row. Use for binary blobs > a few KB. |
| `@Attribute(.transient)` | Don't persist this property. Useful for derived state. |
| `@Attribute(.preserveValueOnDeletion)` | History tracking only — rarely needed. |

### Relationships

```swift
// Kios/Models/Bookmark.swift (sketch)
@Model
final class Bookmark {
    var book: Book?
    var locatorJSON: String
    var createdAt: Date
}

@Model
final class Book {
    @Relationship(deleteRule: .cascade, inverse: \Bookmark.book)
    var bookmarks: [Bookmark] = []
}
```

Set `inverse:` on one side, leave the other implicit. `deleteRule`:

- `.nullify` (default) — clear the relationship, keep the related rows.
- `.cascade` — delete related rows when the owner is deleted.
- `.deny` — fail the delete if related rows exist.
- `.noAction` — programmer's problem; you handle it.

## ModelContainer

Single source of truth for the schema. Defined once, passed into the SwiftUI environment, and shared between app and extensions.

```swift
// Kios/App/ModelContainerFactory.swift
extension ModelContainer {
    static func kios() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 Bookmark.self, Source.self
        )
    }

    static func kiosInMemory() throws -> ModelContainer {
        try ModelContainer(
            for: ..., 
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
```

Then in the app:

```swift
// Kios/App/KiosApp.swift
WindowGroup {
    RootView()
        .environment(environment)
        .modelContainer(environment.modelContainer)
        .environment(\.modelContext, environment.modelContext)
}
```

Tests use `kiosInMemory()` — same schema, no disk side effects.

### Migrations

This codebase deliberately skips migrations: per `CLAUDE.md`, the app has no shipped users yet, so schema changes are direct edits. When the app ships, switch to `VersionedSchema` + `SchemaMigrationPlan`.

Until then, if you need to drop incompatible data after a schema rename, use a UserDefaults-gated one-shot wipe:

```swift
// Kios/App/ModelContainerFactory.swift
static let watermarkWipeFlagKey = "kios.readingStats.watermarkModelWipeApplied.v1"

@MainActor
static func applyWatermarkModelWipeIfNeeded(
    context: ModelContext,
    defaults: UserDefaults = .standard
) {
    guard !defaults.bool(forKey: watermarkWipeFlagKey) else { return }
    try? context.delete(model: ReadingSession.self)
    try? context.save()
    defaults.set(true, forKey: watermarkWipeFlagKey)
}
```

Bump the flag suffix on each future wipe.

## @Query in views

`@Query` drives a live-updating fetch into a SwiftUI `View`:

```swift
struct LibraryView: View {
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    var body: some View {
        List(books) { BookRow(book: $0) }
    }
}
```

Filter with `#Predicate`:

```swift
@Query(
    filter: #Predicate<Book> { $0.archived == false },
    sort: \Book.addedAt,
    order: .reverse
)
private var activeBooks: [Book]
```

### Dynamic @Query

To vary the predicate at runtime, drive it from a property:

```swift
struct SourceBooksView: View {
    let sourceID: UUID

    @Query private var books: [Book]

    init(sourceID: UUID) {
        self.sourceID = sourceID
        _books = Query(
            filter: #Predicate { $0.source.id == sourceID },
            sort: \.addedAt, order: .reverse
        )
    }
}
```

### Predicate gotchas

- `#Predicate` macros run at compile time; only a subset of Swift is supported (no closures, no most function calls, comparisons + boolean ops + simple member access).
- KeyPaths into `@Model` properties become Sendable automatically thanks to `InferSendableFromCaptures` (see `project.yml:23`).
- **Don't filter on computed properties.** Predicates run against the persistent store, which doesn't know about your computed property. Filter on `filename`, not `fileURL`. See the comment on `Book.fileURL` in `Kios/Models/Book.swift`.

## ModelContext

Where you insert, fetch, update, and save. SwiftUI injects one via `.modelContainer(_:)`.

```swift
// Kios/Services/SyncService.swift
@MainActor
final class SyncService {
    private let context: ModelContext

    private func currentLocalProgress(for bookID: UUID) -> ReadingProgress? {
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return try? context.fetch(descriptor).first
    }

    private func upsertLocal(...) {
        if let existing = currentLocalProgress(for: bookID) {
            existing.locatorJSON = locatorJSON       // mutation auto-tracked
            existing.updatedAt = .now
        } else {
            context.insert(ReadingProgress(...))     // explicit insert
        }
        try? context.save()
    }
}
```

Note: mutating a fetched model is enough — SwiftData tracks changes. `context.insert` is only for *new* instances.

### FetchDescriptor

```swift
var descriptor = FetchDescriptor<Book>(
    predicate: #Predicate { $0.archived == false },
    sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
)
descriptor.fetchLimit = 50
descriptor.relationshipKeyPathsForPrefetching = [\.source]
let books = try context.fetch(descriptor)
```

`relationshipKeyPathsForPrefetching` avoids the N+1 query problem when iterating a related field.

## Concurrency — the rules

**`ModelContext` and `@Model` instances are NOT `Sendable`.** Each context is bound to the actor that created it. Each model is bound to the context that fetched it.

### Rule 1: don't share contexts across actors

```swift
// ❌ wrong
let context: ModelContext = ...   // @MainActor
Task.detached {
    context.insert(...)             // crash or undefined behavior
}

// ✅ right
Task.detached {
    let context = ModelContext(container)
    context.insert(...)
    try context.save()
}
```

### Rule 2: don't share models across actors

```swift
// ❌ wrong
let book: Book = ...    // fetched on main actor
Task.detached {
    print(book.title)   // accessing another context's instance
}

// ✅ right
let id = book.persistentModelID
Task.detached {
    let context = ModelContext(container)
    guard let book = context.model(for: id) as? Book else { return }
    // safe to use `book` here.
}
```

This is enshrined in `Kios/Models/CONVENTIONS.md`.

### Rule 3: don't long-store models on `@Observable`

A `Book` reference held by an `@Observable` view model survives past the view's lifetime. The owning `ModelContext` may dissolve out from under it. Either:

- Hold the `PersistentIdentifier` and re-fetch on demand, or
- Hold the model only inside `View.body` (via `@Query` or local `@State`).

## Anti-patterns

- `@unchecked Sendable` on `@Model` classes — see `Kios/Models/CONVENTIONS.md`. Silently allows races.
- Capturing `ModelContext` from one actor into another actor's closure.
- Filtering `@Query` on a computed property.
- Calling `context.save()` in a loop instead of once at the end of a batch.

## Performance

- **Batch saves.** `context.save()` is the slow call. Insert/update many rows, save once.
- **Prefetch relationships.** Set `relationshipKeyPathsForPrefetching` on `FetchDescriptor` when you'll touch a relationship on every result.
- **Limit fetches.** Set `fetchLimit` for pickers/previews. `@Query` doesn't expose `fetchLimit` directly; build a custom view model if you need it.
- **`@Attribute(.externalStorage)`** for large blobs (cover images > a few KB). SwiftData stores them as files alongside the database, keeps row sizes small.

## Patterns from this codebase

### Shared container with an App Intent

`OpenMostRecentBookIntent` lives in the `KiosControls` app-extension, but reads from the **same** SwiftData store as the main app:

```swift
// Kios/Intents/OpenMostRecentBookIntent.swift
@MainActor
func perform() async throws -> some IntentResult {
    let container = try ModelContainer.kios()
    let context = ModelContext(container)
    guard let book = MostRecentBookSelector.pick(in: context) else {
        throw OpenMostRecentBookError.noBook
    }
    BookOpenCoordinator.shared.request(book.id)
    return .result()
}
```

The factory is the single source of truth — the extension calls the same `ModelContainer.kios()` the app does. See [`app-intents-and-controls.md`](app-intents-and-controls.md) for the full extension story.

### Sentinel rows vs nil

`Book.source` is non-optional and points to a `Source` row. Imported local books get a singleton `Source.local` row rather than `nil`. Reasons: predicates are simpler (`source == local`), and the cardinality is clearer in the data.

### Persisting only what survives

`Book.filename` is stored, not `Book.fileURL`. iOS regenerates the app-container UUID across reinstalls, invalidating any absolute URL stored across launches. Recompute the URL on access.

## See also

- `Kios/Models/CONVENTIONS.md` — the canonical rules.
- [`swift-concurrency.md`](swift-concurrency.md) — actor isolation, `Sendable`, `sending`.
- [`app-intents-and-controls.md`](app-intents-and-controls.md) — sharing a container with an extension.
