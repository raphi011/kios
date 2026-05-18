# Architecture: structure, audit, and improvements

How modern iOS apps are typically structured, where this codebase already gets it right, and concrete recommendations to improve readability, testability, and maintainability.

This isn't a prescriptive rewrite — most of the structure here is good. The recommendations are ranked by impact-to-effort ratio.

## Where modern iOS apps land

There's no canonical "iOS architecture." But the patterns most successful apps converge on:

### 1. Layered, not "MV-something"

```
┌──────────────────────────────────────┐
│   Views (SwiftUI)                    │  ← presentational, thin
├──────────────────────────────────────┤
│   View Models / View State           │  ← optional, for complex screens
├──────────────────────────────────────┤
│   Services (use cases / facades)     │  ← @MainActor, owns ModelContext
├──────────────────────────────────────┤
│   Domain Backends (protocols)        │  ← Strategy boundary
├──────────────────────────────────────┤
│   Clients (HTTPClient, KOSyncClient) │  ← thin wrappers
├──────────────────────────────────────┤
│   Foundation (URLSession, SwiftData) │
└──────────────────────────────────────┘
```

Each layer has one direction of dependency (down). Tests mock at protocol boundaries.

### 2. Modular package boundaries

Pure-logic code lives in **a Swift Package**, not the app target. Why:

- `swift test` is ~1s, `xcodebuild test` is ~30s.
- Package code can't accidentally `import UIKit` or `import SwiftData`.
- Encourages a clean domain layer.

This codebase already does this with `Core/`.

### 3. Composition over inheritance

`@Model` doesn't support inheritance. `@Observable` works best with `final class`. View composition via small `View` structs replaces what used to be base controllers.

### 4. Protocol-based seams

Inject dependencies as protocols (`any SyncBackend`, `any CatalogBackend`). Production code wires concrete instances; tests wire fakes.

### 5. Single-binary builds, multiple SwiftUI scenes

`@main App` + `WindowGroup` + scene-bound state. No more `AppDelegate` glue for most apps. App Intents extensions live in separate targets but share a SwiftData store.

## This codebase: structural audit

### What's working well

| Area | Notes |
|------|-------|
| **`Core/` SPM package** | Pure-Foundation, testable in 1s. The model rule: if it doesn't need SwiftData/UIKit/Readium, it goes here. Cleanly enforced. |
| **Layered networking** | `URLSession` → `HTTPClient` → `KOSyncClient` → `KOSyncBackend` → `SyncService` → UI. Each layer has one job; each is independently testable. |
| **Protocol-based backends** | `SyncBackend` and `CatalogBackend` abstract Kobo vs KOSync vs local. Adding a new server protocol means writing one new conformance, not touching the UI. |
| **`URLProtocol` mocking** | Beats third-party HTTP-mock libraries on every axis (zero deps, full request inspection, works for Readium too). |
| **`SourceContext` aggregate** | Per-source runtime bundle is exactly the right abstraction — keeps `book.source.id` → backend routing one indirection deep. |
| **Editorial design system** | `Kios/Views/Editorial/` is a tokenized design system. Swappable fonts, semantic colors. New screens use existing components instead of reinventing. |
| **Coordinator for cold-launch handoff** | `BookOpenCoordinator.shared` correctly handles both warm and cold launches from App Intents. Both `.onChange` and `.onAppear` drain it. |
| **Strict concurrency on** | `SWIFT_STRICT_CONCURRENCY: complete` + `InferSendableFromCaptures`. The compiler catches a lot you'd otherwise miss. |
| **Hard-won knowledge in code** | `CLAUDE.md` and `Kios/Models/CONVENTIONS.md` document non-obvious traps (status bar reflow, `@unchecked Sendable`, MockURLProtocol races). |

### Tension points

The codebase is healthy. These are friction points to consider, in rough priority order:

#### 1. `AppEnvironment` is doing too much (444 LOC)

`Kios/App/AppEnvironment.swift` owns:

- `ModelContainer` + `modelContext`
- `AuthStore`, `LibraryService`, `ReadingStatsService`, `LocalImportService`, `localSource`
- `sourceContexts` dictionary + `makeContext` / `removeSource` / `tearDown`
- `deviceID` Keychain plumbing
- `activeReader` route + `openReader` helper
- Sample-book seeding
- Source kind probes
- A one-off "multi-source wipe"

It's a **service locator**. That's not wrong — service locators are pragmatic for app-shell composition. But this one has accumulated three distinct responsibilities:

- **Composition root** (build services from config).
- **Source-credential lifecycle** (add/remove/probe sources).
- **Navigation routing** (`activeReader`, `openReader`).

**Recommendation**: split into three types that compose under one umbrella, or extract two:

```swift
@MainActor @Observable
final class AppEnvironment {
    let container: ModelContainer
    let context: ModelContext
    let auth: AuthStore
    let library: LibraryService
    let stats: ReadingStatsService
    let localImporter: LocalImportService
    let deviceID: String
    let localSource: Source

    let sources: SourceRegistry          // ← extract
    let router: ReaderRouter             // ← extract
}

@MainActor @Observable
final class SourceRegistry {
    private(set) var contexts: [UUID: SourceContext] = [:]
    func makeContext(for source: Source) throws -> SourceContext { ... }
    func tearDown(sourceID: UUID) { ... }
}

@MainActor @Observable
final class ReaderRouter {
    var activeReader: ReaderRoute?
    func openReader(_ bookID: UUID) { ... }
}
```

Wins:

- `AppEnvironment` shrinks to ~80 LOC and reads top-to-bottom in one sitting.
- `SourceRegistry` and `ReaderRouter` are independently testable.
- Views can take `@Environment(ReaderRouter.self)` instead of pulling the full env.
- Surface area for new features (e.g. tab-based deep links) lives in `ReaderRouter`, not the kitchen sink.

This is the highest-impact refactor on the list.

#### 2. Force-unwrapped `localSource: Source!`

```swift
// Kios/App/AppEnvironment.swift
private(set) var localSource: Source!
```

The comment honestly admits this:

> Force-unwrapped because the seed runs before any caller can observe `self`.

That's correct **today**. But IUO is a footgun — any future caller (background task, intent, schema migration) that doesn't follow the init contract gets a crash.

**Recommendation**: make `localSource` non-optional by moving its construction into `init` (failable or throwing). Then the type system guarantees it's set:

```swift
init() throws {
    let container = try ModelContainer.kios()
    let ctx = container.mainContext
    let localSource = Self.seedLocalSource(in: ctx)   // returns Source
    self.modelContainer = container
    self.modelContext = ctx
    self.localSource = localSource
    ...
}

private static func seedLocalSource(in ctx: ModelContext) -> Source {
    let all = (try? ctx.fetch(FetchDescriptor<Source>())) ?? []
    if let existing = all.first(where: { $0.kind == .local }) { return existing }
    let local = Source(...)
    ctx.insert(local)
    try? ctx.save()
    return local
}
```

Now `localSource: Source` (no `!`), and the call site is the same.

#### 3. Big views with too much local state

| File | LOC | `@State` / `@Query` / `@AppStorage` / `@Environment` count |
|------|-----|-------|
| `LibraryRootView.swift` | 519 | 14 |
| `ReaderView.swift` | ~800+ | **33** |
| `HomeRootView.swift` | 191 | 5 |
| `SettingsView.swift` | 222 | 6 |

`ReaderView` is the standout. 33 state-tracking properties in one view means:

- Hard to read top-to-bottom.
- Hard to reason about which state drives which UI.
- Hard to test individual subsystems (HUD, scrubber, prompt resolution).

**Recommendation**: introduce a `@Observable` view model for `ReaderView` and `LibraryRootView`. Concretely, for `ReaderView`:

```swift
@MainActor @Observable
final class ReaderViewModel {
    var publication: Publication?
    var initialLocator: Locator?
    var loadError: String?
    var currentLocator: Locator?
    var positions: [Locator] = []

    // HUDs
    var fontHUD: Int?
    var brightnessHUD: Int?

    // Scrubber
    var scrubProgress: Double?
    var scrubCommitPending: Bool = false

    // Prompts / jumps
    var pendingPrompt: PromptInfo?
    var pendingJump: Locator?
    var pendingJumpSource: AdvanceSource?

    func resolveOpen(book: Book, sync: SyncService) async { ... }
    func pushLocator(_ locator: Locator, book: Book, sync: SyncService) async { ... }
    func commitScrub(...) async { ... }
}
```

Then `ReaderView` becomes:

```swift
struct ReaderView: View {
    let bookID: UUID
    @State private var vm = ReaderViewModel()

    @AppStorage("reader.fontSizePct") private var fontSizePct: Int = 100
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ""

    @Environment(AppEnvironment.self) private var env
    @Query private var books: [Book]
    ...
}
```

Wins:

- View body shrinks to layout + binding. Easier to read.
- VM is testable in isolation. Resolution logic (`resolveOpen`, `commitScrub`) can be unit-tested without mounting the SwiftUI view.
- New behaviors get added to the VM, not stuffed into more `@State`.

Keep `@AppStorage` and `@Query` in the view — they're SwiftUI-bound and don't translate cleanly into VM state.

`LibraryRootView` (519 LOC) likely needs the same plus extraction of subviews:

```
LibraryRootView (~150)
 ├── SourcePickerHeader (already extracted)
 ├── LibraryBookList (new)
 ├── LibrarySectionHeader (new)
 ├── LibraryEmptyState (new)
 └── LibraryViewModel (new, handles filter/sort state)
```

#### 4. Services are hard to mock at the SwiftUI seam

`SyncService` is a concrete class taking a `ModelContext`. Views reach it via `env.sourceContexts[sourceID]?.sync` and call methods on it. No protocol seam at this layer.

For most services this is fine — the protocol is at the backend layer (`SyncBackend`), so tests inject a mock backend and let the real service run. `SyncServiceTests.swift` does exactly this.

But for views that want to mock the entire service (e.g. a preview that needs synthetic `OnOpenAction.applyServer`), there's no easy seam.

**Recommendation**: only worth it if you're going to use it. Two paths:

- **Don't**. Test services with mock backends (current pattern). Run views in Previews with stubbed env. This is the lowest-friction path and probably right for app size.
- **Protocolize on demand.** When a specific view test needs a mock service, extract a `SyncServicing` protocol just for that. Don't pre-emptively protocolize all services.

Current state is fine. Flag this only if iOS test code grows substantially.

#### 5. iOS-side concurrency could be tighter on services

Services like `SyncService` are `@MainActor`, which is correct — they touch `ModelContext`. But callers in the view layer use `Task { await service.method() }` patterns that inherit main actor, so the awaits don't actually hop off the main thread. Heavy work (e.g. hashing inside `DocumentHasher`) is in `Core/` and synchronous; it runs on the main thread because that's where the caller is.

For the current scale (a download every few minutes, hashing a single MD5) this is fine. If you grow to bulk imports or background sync, push work-loop methods onto a background actor and use `MainActor.run { context.save() }` for the SwiftData hop.

#### 6. Tests follow the production layout — keep doing this

`KiosTests/` mirrors `Kios/`:

```
KiosTests/App/         → Kios/App/
KiosTests/Services/    → Kios/Services/   (2051 LOC of tests — well covered)
KiosTests/Networking/  → Kios/Networking/ (579 LOC of tests)
KiosTests/Models/      → Kios/Models/
KiosTests/Views/       → Kios/Views/      (only 180 LOC of tests — see #4)
KiosTests/Helpers/     → shared test utilities
```

This is the right shape. Two minor refinements:

- **Add a `KiosTests/Fixtures/` README** listing what each fixture exists for and where it came from. (`KiosTests/Fixtures/` exists but its contents aren't self-documenting.)
- **Promote `TestSource.swift` patterns** — `KiosTests/Helpers/TestSource.swift` looks like the start of a shared factory. Add factories for `Book`, `Source`, `ReadingProgress` so service tests don't reinvent the boilerplate.

#### 7. `@preconcurrency import` in `ReaderView`

```swift
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumNavigator
```

`@preconcurrency` silences Sendable warnings from modules that haven't fully adopted strict concurrency. Pragmatic, but worth tracking — when Readium fully adopts Sendable (every release narrows the gap), drop the attribute.

**Recommendation**: leave a `// TODO(readium): drop @preconcurrency when v3.X is current` comment with the target Readium version. Tracked in `docs/readium-followups.md`.

## Recommended additions

### A `KiosUI` module (Phase 2, optional)

If the design system grows or you want to use it in tests/previews without booting the app, extract `Kios/Views/Editorial/` into a SPM module:

```
Core/                     → pure-Foundation
KiosUI/                   → SwiftUI design system (new)
  Sources/KiosUI/
    Editorial/
    Components/
Kios/                     → app target, depends on Core + KiosUI
```

Wins:

- Design system is independently testable (snapshot tests against the package).
- Faster `swift test` for design-only changes.
- Forces the design system to *not* leak app-specific knowledge.

Don't do this until you have a second consumer (Mac Catalyst app, Watch app, separate marketing target). Premature modularization is its own debt.

### A `domain/` layer in Core

Currently `Core/` mixes:

- Domain types (`BookFormat`, `CanonicalProgress`, `BookIdentity`)
- Protocols (`SyncBackend`, `CatalogBackend`)
- Clients (`HTTPClient`, `KOSyncClient`, `KoboClient`)
- Plumbing (`MockURLProtocol`, `KeychainStore`, `AuthStore`)

This is fine at current size. If `Core/` grows past ~50 files, split into:

```
Core/Sources/Domain/      → CanonicalProgress, BookIdentity, BookFormat
Core/Sources/Net/         → HTTPClient, MockURLProtocol, HTTPError
Core/Sources/Sync/        → SyncBackend, KOSync*, Kobo*
Core/Sources/OPDS/        → OPDSClient, OpenSearchDescriptor
```

Each as a separate SPM target inside the `Core` package. Imports become more explicit.

Don't do this until the file count justifies it (~50+).

## Recommended *non*-changes

A few things people often add that wouldn't help here:

- **Combine + reactive streams.** SwiftUI + `@Observable` + async/await covers everything Combine used to. Don't pull it in.
- **VIPER/RIB/Clean.** These were responses to UIKit's lack of composability. SwiftUI doesn't have that problem. Stay with thin views + services.
- **A DI container library (Swinject, Factory).** `AppEnvironment` already does this work. Library overhead > value for an app this size.
- **A snapshot-testing library.** Not currently needed. If you add one, prefer Swift Testing's inline expectations over a generic library.

## Ranked recommendations

| # | Change | Effort | Payoff | Status |
|---|--------|--------|--------|--------|
| 1 | Split `AppEnvironment` into env + `SourceRegistry` + `ReaderRouter` | M | H — cleanest single refactor | ✅ done |
| 2 | Introduce `ReaderViewModel` for `ReaderView`'s 33-state mess | M | H — biggest single readability win | ✅ done |
| 3 | Remove `localSource: Source!` IUO | S | M — type-safety, no IUO crashes | ✅ done |
| 4 | Extract `LibraryRootView` subviews + view model | M | M — 519 LOC → 5 files of ~100 | open |
| 5 | Document `KiosTests/Fixtures/` + grow `Helpers/` factories | S | M — faster new tests | open |
| 6 | Drop `@preconcurrency` when Readium catches up | S | L — future-proofing | open |
| 7 | Extract `KiosUI` SPM module | M | L — only if you grow a second consumer | open |
| 8 | Split `Core/` into sub-targets | L | L — only at ~50+ files | open |

### What landed (recs 1–3)

- `Kios/App/SourceRegistry.swift` (95 LOC) — owns per-source `SourceContext` lifecycle.
- `Kios/App/ReaderRouter.swift` (21 LOC) — owns `activeReader` + `openReader`.
- `Kios/App/AppEnvironment.swift` — shrank 444 → 383 LOC, now a thin composition root + workflows (addSource, removeSource, refreshLibrary, sample seeding).
- `Kios/App/AppEnvironment.swift` — `localSource: Source!` → `let localSource: Source` via static `loadOrSeedLocalSource(in:)`.
- `Kios/Views/Reader/ReaderViewModel.swift` (601 LOC) — engine state (publication, locator, scrub, TOC, prompts) + the heavy methods. Takes resolved dependencies as parameters; no `env` reference, so it's testable in isolation.
- `Kios/Views/Reader/ReaderView.swift` — shrank 979 → 507 LOC. `@State` dropped 16 → 6 (only UI bookkeeping: `vm`, `uiVisible`, `showContents`, `fontHUD`, `brightnessHUD`, `selectionProbe`).

Call-site sweep: `env.sourceContexts` → `env.sources.contexts`; `env.context(for:)` → `env.sources.context(for:)`; `env.openReader(id)` → `env.router.openReader(id)`; `$env.activeReader` → `@Bindable var router = env.router; $router.activeReader`.

Start the remaining work with #4 — `LibraryRootView` is the next-largest file and benefits from the same VM treatment.

## What to read next

- [`swift-concurrency.md`](swift-concurrency.md) — `@MainActor` boundaries on services.
- [`swiftdata.md`](swiftdata.md) — why `localSource` initialization order matters.
- [`testing.md`](testing.md) — how to add `Helpers/` factories.
- [`swiftui-and-hig.md`](swiftui-and-hig.md) — when to lift `@State` into an `@Observable`.
- `Kios/Models/CONVENTIONS.md` — the codebase's hard-won concurrency rules.
