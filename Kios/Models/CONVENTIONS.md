# Model conventions

## Concurrency

SwiftData `@Model` classes are reference types, not `Sendable`, and are
bound to the `ModelContext` they were fetched from. They are NOT safe to
pass across actor boundaries.

### Rule

When a service running on one actor needs to hand a model to another
context (e.g. background download → main-thread UI update), pass a
`PersistentIdentifier` and let the consuming actor re-fetch:

```swift
// On main actor
let id = book.persistentModelID

Task.detached {
    let context = ModelContext(container)
    guard let book: Book = context.model(for: id) as? Book else { return }
    // mutate `book` on this context, save here.
}
```

### Anti-patterns

- `@unchecked Sendable` on `@Model` classes — silently allows races.
- Capturing `ModelContext` from another actor in a closure.
- Storing `Book` instances on a long-lived `@Observable` object that
  outlives its context.
