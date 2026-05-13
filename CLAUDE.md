# Kios

iOS EPUB reader app backed by Calibre-Web-Automated. Two sync protocols: kosync and Kobo.

## Commands

```bash
make test           # all tests (Core + iOS)
make test-core      # Core SPM tests only (~1s, sequential)
make test-ios       # iOS app tests via xcodebuild (~30s)
make xcodegen       # regenerate .xcodeproj from project.yml
make clean          # nuke DerivedData + SPM build cache
```

## Architecture

Two modules:

- **`Core/`** — local SPM package. Pure-Foundation: HTTP clients, sync backends, auth, hashing. No UIKit/SwiftData/Readium. Test with `swift test`.
- **`Kios/`** — iOS app target. SwiftData models, Readium integration, SwiftUI views, services. Test with `xcodebuild test`.

Rule of thumb: if it doesn't need SwiftData/UIKit/Readium, it belongs in Core.

## Key Gotchas

- **`project.yml` is source of truth** — `.xcodeproj` is generated and gitignored. Run `make xcodegen` after changing targets/deps.
- **Core tests must run sequentially** — `MockURLProtocol.handler` is a shared static. `--no-parallel` is baked into the Makefile.
- **Swift strict concurrency: complete** — all code must be Sendable-correct. No `@unchecked Sendable` on `@Model` classes.
- **SwiftData models are NOT Sendable** — pass `PersistentIdentifier` across actor boundaries, re-fetch on the other side. See `Kios/Models/CONVENTIONS.md`.
- **First build resolves ~1 GB of Readium deps** — subsequent builds are incremental.

## Code Style

- Swift 5.10, iOS 17+
- SwiftUI for views, SwiftData for persistence
- `@Observable` view models where needed
- Protocols for sync backends (`SyncBackend`) to keep kosync/Kobo interchangeable

## Testing

- Core: Swift Testing framework, `MockURLProtocol` for HTTP stubbing
- iOS: XCTest via xcodebuild against simulator
- Fixtures in `KiosTests/Fixtures/`
