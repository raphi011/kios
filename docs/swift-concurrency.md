# Swift concurrency best practices

Reference for working under `SWIFT_STRICT_CONCURRENCY: complete` (see `project.yml:21`). The build also enables `InferSendableFromCaptures`, which is Swift 6 default behavior — so write code that is **Swift 6-clean**, not just Swift 5.10-clean.

If a snippet here compiles with strict concurrency, it will keep compiling after the Swift 6 jump. If it relies on `@unchecked Sendable` or implicit isolation, it won't.

## Mental model

Every value, function, and stored property has an **isolation domain**. Three flavors:

- **Actor-isolated** — bound to an actor (custom `actor X`, the `@MainActor` singleton, or a global actor).
- **Nonisolated** — runs anywhere; can only touch its own params + `Sendable` state.
- **Sendable-or-not** — types are flagged as safe to cross domains (`Sendable`) or not.

The compiler enforces that values crossing a domain boundary are `Sendable`. That's the whole game.

## Sendable

A type is `Sendable` if it's safe to share/copy across actors. Defaults:

- Value types with only `Sendable` stored properties → automatically `Sendable`.
- `final class` with only `let` `Sendable` stored properties → manually `Sendable`.
- Closures captured across actors → must be `@Sendable` (or `sending`).

```swift
// Core/Sources/Core/Net/HTTPClient.swift
public struct BasicCredentials: Sendable, Equatable {
    public let username: String
    public let password: String
}

public struct HTTPClient: Sendable {
    private let session: URLSession                  // Sendable (Foundation)
    private let credentials: BasicCredentials?       // Sendable (above)
}
```

Both are `struct` with `let` `Sendable` properties → free `Sendable` conformance, no `@unchecked`.

### Anti-pattern: `@unchecked Sendable` on `@Model`

```swift
// ❌ silences the compiler; doesn't make it safe
extension Book: @unchecked Sendable {}
```

`@Model` classes are reference types bound to a `ModelContext`. Marking them `Sendable` lies to the compiler. Pass `PersistentIdentifier` and re-fetch on the consuming actor instead — see [`swiftdata.md`](swiftdata.md) and `Kios/Models/CONVENTIONS.md`.

### `InferSendableFromCaptures`

This codebase enables the upcoming feature in `project.yml:23`. It makes `KeyPath`, `\.foo`, and closures-with-Sendable-captures automatically `Sendable`. Practical impact: SwiftData's `#Predicate { $0.id == … }` macro expansion stops emitting `Sendable` warnings on every `@Model var`.

## MainActor

Use `@MainActor` to bind code to the main thread. The codebase applies it generously to services and view models touching `ModelContext` or UIKit:

```swift
// Kios/Services/SyncService.swift
@MainActor
final class SyncService {
    private let context: ModelContext   // ModelContext is main-actor-bound here
    ...
}

// Kios/Views/Reader/ReaderContainerVC.swift
@MainActor
final class ReaderContainerVC: UIViewController { ... }
```

### When to use `@MainActor`

- **Always** for view models / services that own a `ModelContext` from the SwiftUI scene.
- **Always** for anything touching UIKit (`UIView`, `UIViewController`, `UIApplication`).
- For helpers called only from `View.body` — usually not needed, since `View.body` is implicitly `@MainActor` in SwiftUI iOS 17+.

### `@MainActor` propagation

- Marking a class `@MainActor` makes every method and stored property `@MainActor` by default.
- Override on a per-method basis with `nonisolated`:

```swift
@MainActor
final class Foo {
    let id: UUID                          // Sendable, isolated to main

    nonisolated init(id: UUID) {          // callable from any actor
        self.id = id
    }
}
```

Use `nonisolated` for pure helpers and `init`s that don't touch isolated state.

## Custom actors vs `@MainActor`

Default to `@MainActor` unless you have a reason to use a custom actor. Reasons to spin a custom actor:

- **Hot path off the main thread** — heavy CPU work, file I/O, hash computation.
- **Stateful background worker** — e.g. a download queue, a span resolver cache.
- **Serializing mutations** to a non-`Sendable` resource that the main thread doesn't need direct access to.

```swift
actor SpanResolverCache {
    private var cache: [URL: [String: String]] = [:]

    func resolve(...) -> String? { ... }
}
```

Don't reach for `actor` if all you needed was thread-safety on a single shared resource that the main actor already touches. Just keep it `@MainActor`.

## async / await

### `await` on the main actor

A `Task { … }` started from a `@MainActor` context inherits the main actor:

```swift
// Kios/Views/RootView.swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active {
        Task {                            // implicitly @MainActor
            await withTaskGroup(of: Void.self) { group in
                for ctx in env.sourceContexts.values {
                    guard let sync = ctx.sync else { continue }
                    group.addTask { await sync.flushAllPending() }
                }
            }
        }
    }
}
```

Note that `sync.flushAllPending()` is itself `@MainActor`-isolated — the awaits hop back to main automatically.

### `Task.detached`

Use only when you want to **escape the current actor**:

```swift
Task.detached {
    let context = ModelContext(container)
    guard let book: Book = context.model(for: id) as? Book else { return }
    // mutate `book` on this detached context, save here.
}
```

`Task.detached` does NOT inherit isolation or priority. Use sparingly.

### Cancellation

Tasks cancel cooperatively. Always check `Task.isCancelled` in long loops, and let `try await` propagate `CancellationError`:

```swift
for await item in stream {
    try Task.checkCancellation()
    process(item)
}
```

SwiftUI's `.task { … }` cancels its task on view disappear. `.task(id:)` cancels and restarts when `id` changes.

## Structured concurrency

Prefer `async let` and `TaskGroup` over manual `Task { … }` — they're scoped and cancellation-correct:

```swift
async let titles = client.fetchTitles()
async let covers = client.fetchCovers()
let (t, c) = try await (titles, covers)

// or
await withTaskGroup(of: Void.self) { group in
    for ctx in contexts { group.addTask { await ctx.flush() } }
}
```

`Task { … }` is **unstructured** — it outlives the enclosing scope unless you store and `.cancel()` it. Use it when you want fire-and-forget, otherwise reach for the structured forms.

## Sending parameters (Swift 6)

When you need to hand off a non-`Sendable` value across an actor boundary once (and never use it again on the originating side), use `sending`:

```swift
func process(_ value: sending NonSendableType) async { ... }
```

The compiler verifies that the caller doesn't reuse the value after the call. Useful for moving a freshly-constructed object across to a background actor.

## Common compiler errors and fixes

| Error | Fix |
|-------|-----|
| `Capture of 'self' with non-sendable type 'X' in a `@Sendable` closure` | Make `X` `Sendable`, or capture only what you need: `[id = self.id]`. |
| `Type 'X' does not conform to the 'Sendable' protocol` | Add `Sendable` conformance; if it's a class, make it `final` + `let`-only. |
| `Main actor-isolated property 'foo' can not be referenced from a Sendable closure` | Capture an isolated snapshot, or hop via `await MainActor.run { ... }`. |
| `Sending '...' risks causing data races` | Use `sending` parameter, or copy/freeze the value first. |
| `Reference to property 'X' in closure requires explicit use of 'self'` | This is the regular escaping-closure rule, not concurrency. Add `self.` or `[weak self]`. |

## Patterns from this codebase

### Closure callbacks across actors

`ReaderHost` (SwiftUI) bridges to `ReaderContainerVC` (UIKit). Callbacks declared `@Sendable` propagate isolation cleanly:

```swift
// Kios/Views/Reader/ReaderHost.swift
var onLocatorChange: @Sendable (Locator) -> Void
```

The container then re-binds these on every `updateUIViewController` — SwiftUI re-creates closures on each render.

### Re-fetching across contexts

```swift
// `Kios/Models/CONVENTIONS.md` rule:
let id = book.persistentModelID

Task.detached {
    let context = ModelContext(container)
    guard let book: Book = context.model(for: id) as? Book else { return }
    // mutate `book` on this context, save here.
}
```

Never capture `book` directly into a `Task.detached`. Pass the ID, re-fetch.

### Weak-self in long-lived closures

```swift
// Kios/Views/Reader/ReaderContainerVC.swift
selectionProbe.hasSelection = { [weak vc] in vc?.hasCurrentSelection() ?? false }

nav.addObserver(.activate { [weak self] _ in
    self?.onCenterTap?()
    return true
})
```

Readium observer closures outlive view-controller pop. Always `[weak self]` to avoid retain cycles; Readium 3.9+ adapter closures themselves capture `self` weakly (see `ReaderContainerVC.swift:49`).

## See also

- `Kios/Models/CONVENTIONS.md` — SwiftData-specific concurrency rules.
- [`swiftdata.md`](swiftdata.md) — cross-actor patterns for `@Model`.
- [`testing.md`](testing.md) — `@Suite(.serialized)` for tests sharing static mutable state.
