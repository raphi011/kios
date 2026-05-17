# Kios

iOS EPUB reader app. Talks to self-hosted servers over OPDS, KOSync, and Kobo sync protocols.

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

- **`Kios/Views/Editorial/`** — shared design system (tokens, nav bar, list, segmented, book row, settings row). Newsreader/Geist are stubbed via system `.serif` / default — swap in `EditorialTheme.swift` when bundling fonts; call sites stay untouched.

## Key Gotchas

- **`project.yml` is source of truth** — `.xcodeproj` is generated and gitignored. Run `make xcodegen` after changing targets/deps.
- **Core tests must run sequentially** — `MockURLProtocol.handler` is a shared static. `--no-parallel` is baked into the Makefile.
- **Swift strict concurrency: complete** — all code must be Sendable-correct. No `@unchecked Sendable` on `@Model` classes.
- **SwiftData models are NOT Sendable** — pass `PersistentIdentifier` across actor boundaries, re-fetch on the other side. See `Kios/Models/CONVENTIONS.md`.
- **First build resolves ~1 GB of Readium deps** — subsequent builds are incremental.
- **No installed users yet — no SwiftData migrations needed.** The app has not shipped or been installed anywhere outside this dev machine. Schema changes (adding/removing fields, changing optionality, renaming) can land as direct edits to the `@Model` classes; do not introduce `VersionedSchema` / `SchemaMigrationPlan` / migration tests. When the app ships, revisit this and add migrations from that point forward.
- **`ReaderView` chrome below `ReaderHost`** — use `.ignoresSafeArea(edges: [.top, .horizontal])` + `.safeAreaInset(edge: .bottom) { … }`. Blanket `.ignoresSafeArea()` lets EPUB body text bleed under the bottom strip/floating bar.
- **`git mv` only survives in history if you don't later add a new file at the old path** — if you rename `A.swift → B.swift` then create a fresh `A.swift`, git stages it as delete-old + add-two-new and the rename arrow is lost.

## Code Style

- Swift 5.10, iOS 17+
- SwiftUI for views, SwiftData for persistence
- `@Observable` view models where needed
- Protocols for sync backends (`SyncBackend`) to keep kosync/Kobo interchangeable

## Testing

- Core: Swift Testing framework, `MockURLProtocol` for HTTP stubbing
- iOS: XCTest via xcodebuild against simulator
- Fixtures in `KiosTests/Fixtures/`

## Visual verification

- Screenshot booted sim: `xcrun simctl io <UDID> screenshot /tmp/x.png`
- App bundle: `~/Library/Developer/Xcode/DerivedData/Kios-*/Build/Products/Debug-iphonesimulator/Kios.app`
- Cycle: `xcodebuild … build && xcrun simctl terminate $SIM …kios; xcrun simctl install $SIM <app> && xcrun simctl launch $SIM com.raphi011.kios`
- No CLI tap/scroll exists; AppleScript needs Accessibility — to view non-default tabs/states, temporarily flip `@State` defaults (e.g. `selectedTab`, `uiVisible`) and revert before committing
