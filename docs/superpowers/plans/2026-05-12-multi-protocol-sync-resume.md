# Multi-Protocol Sync — Resume Plan (Phases 6–10)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Date**: 2026-05-12
**Status**: Phases 0–5 complete on `feat/v1`. HEAD: `c211760`. Resuming with Phases 6–10.
**Original spec**: `docs/superpowers/specs/2026-05-11-multi-protocol-sync-design.md`
**Original plan (still authoritative for Tasks 6.1–10.2 *body content*)**: `docs/superpowers/plans/2026-05-11-multi-protocol-sync.md`

This file is a delta on top of the original plan, capturing:
- What changed in Phases 0–5 that downstream tasks need to know about
- Plan-text errors that were corrected during execution
- Conventions/quality bar established by review-with-fix loops

---

## Current state of the codebase

**Branch**: `feat/v1` (cluster of unrelated Reader-view WIP commits may be present; do NOT touch `iOSReader/Views/Reader/*.swift` unless a task explicitly modifies them)

**Test counts**: 78 Core tests, 12 suites, ~0.15s
**Build commands**: `make test-core` (fast, ~1s), `make test-ios` (xcodebuild, ~30s)
**Xcode project**: regenerated via `xcodegen generate` when iOS target's file list changes

### What's in `Core/` (SPM, Foundation-only)

```
Core/Sources/Core/
├── HTTPClient.swift              (existing)
├── HTTPError.swift               (existing)
├── KeychainStore.swift           (existing)
├── AuthStore.swift               (existing — NO activeProtocol field yet)
├── DocumentHasher.swift          (existing)
├── OpenSearchDescriptor.swift    (existing)
├── MockURLProtocol.swift         (existing + .readBodyStream() helper added)
├── Models/
│   └── BookFormat.swift          (★ moved from iOSReader/Models — public)
├── SyncBackend.swift             (★ NEW — BookIdentity, CanonicalProgress, BackendError, SyncBackend protocol)
├── CatalogBackend.swift          (★ NEW — CatalogEntry, CatalogBackend protocol)
├── KOSync/
│   ├── KOSyncClient.swift        (moved here)
│   ├── KOSyncProgressMapper.swift (renamed from ProgressMapper, moved here)
│   └── KOSyncBackend.swift       (★ NEW — SyncBackend adapter)
└── Kobo/
    ├── KoboClient.swift          (★ NEW — initialization, librarySync paginated, fetchState, pushState)
    ├── KoboTypes.swift           (★ NEW — wire types + tolerant decoders + KoboStateUpdate)
    ├── KoboProgressMapper.swift  (★ NEW — locator translation, escapeCSS/unescapeCSS paired)
    └── KoboBackend.swift         (★ NEW — actor implementing SyncBackend + CatalogBackend)
```

### What's in `iOSReader/` (Xcode target)

Unchanged so far. The remaining phases all touch this target:
- Phase 6: SwiftData V2 schema + migration
- Phase 7: `BackendFactory`, `SyncService` refactor
- Phase 8: `LibraryService` mode-switch matching
- Phase 9: Settings UI protocol picker
- Phase 10: README + manual smoke tests

---

## Conventions established in Phases 0–5

Apply these to Phases 6–10. Most differ from the original plan text.

### 1. Mocking pattern (use REAL APIs, not the plan's placeholder names)

The original plan repeatedly wrote `HTTPClient.mocked()` and `HTTPClient.mocked(creds:)` — these helpers **do not exist**. The real pattern, consistent across all 5 test suites that mock HTTP, is:

```swift
// Without credentials
HTTPClient(session: MockURLProtocol.session())

// With Basic auth
HTTPClient(
    session: MockURLProtocol.session(),
    credentials: BasicCredentials(username: "u", password: "p")
)
```

`BasicCredentials` is a struct (NOT a tuple). Reference `KOSyncClientTests` or `KOSyncBackendTests` for the canonical form.

### 2. Test isolation

Every test suite that touches `MockURLProtocol.handler` must:
- Be annotated `.serialized`
- Reset the handler to nil in `init()`

Without these, the shared global handler races across parallel test runs. This is non-negotiable — every Phase 6+ test suite that uses MockURLProtocol must follow the pattern.

### 3. Capture mutated state OUTSIDE the handler closure

`#expect` inside the handler closure doesn't propagate failures cleanly. Pattern:

```swift
nonisolated(unsafe) var capturedPath: String?
MockURLProtocol.handler = { req in
    capturedPath = req.url?.path
    // ... return mock response
}
// ... run code under test ...
#expect(capturedPath == "/expected/path")
```

For body-capture, use the helper `URLRequest.readBodyStream()` added in MockURLProtocol.swift during Task 3.3.

### 4. Timestamp fallbacks: `.distantPast`, NEVER `Date()`

The original plan had `Date()` for missing timestamps. **Reject this.** Last-write-wins reconciliation must treat "age unknown" as "oldest possible" so a timestamp-less server payload never beats a real local write. Apply `.distantPast` everywhere — same fix applied to KOSyncBackend.fetchProgress (Task 5.1) and KoboBackend.fetchProgress (Task 5.2).

### 5. Stubs in `throws` functions: throw, don't `fatalError`

A `throws` function that's a temporary placeholder must throw a typed error, not `fatalError`. Even if the next task replaces the body. Production behavior depends on contract-honoring. Pattern:

```swift
throw BackendError.serverShapeUnexpected(detail: "<method> not yet implemented")
```

### 6. Mutable state across suspension points → actor

If a `class` has `private var` mutated across `async` suspension points, **do not** use `@unchecked Sendable`. Use `actor`. The type system enforces serial access; `nonisolated let` covers immutable Sendable properties so callers can read them without `await`. Reference: KoboBackend (Task 5.4 → fix commit).

### 7. Couple inverses across modules

If module A exposes `escape()` and module B implements `unescape()`, **co-locate them**. The `KoboProgressMapper.escapeCSS` ↔ `KoboBackend` inverse silently coupled across modules — fixed in Task 5.3 by adding `unescapeCSS` next to `escapeCSS` in the mapper plus a round-trip test. Apply the same pattern wherever bidirectional codec logic appears.

### 8. Defensive Codable: skip non-dict entries, tolerate null

The `KoboSyncEntryOrSkip` wrapper and the `decodeContributors` extension establish the pattern. For any field the server might omit, set to null, or shape-shift across versions:

- `decodeIfPresent` for clean absence
- `guard contains(key), try decodeNil(forKey: key) == false` for null tolerance
- Wrapper-as-Optional for stray non-dict array entries (the `Optional: Decodable` form fails to compile due to Swift's existing conditional conformance on `Optional`; use a `Decodable struct Wrapper { let inner: T? }` newtype pattern)

### 9. Decode failure of a single entry must not kill the whole batch

Per-entry `try?`-wrapped decode (Task 2.3 fix). A malformed entitlement in `/v1/library/sync` should drop *only that book*, not break the entire sync.

### 10. Bounded loops

Any `while true` server-controlled loop needs a max-iteration cap that throws `BackendError.serverShapeUnexpected` on overflow. Pattern: `static var maxXxxPages: Int { 100 }` on the type. Defense-in-depth against malicious or buggy servers.

### 11. Inline small fixes; dispatch subagents for non-trivial fixes

For 1–3 line review-flagged fixes (escape paths, doc comments, sentinel constants), edit inline and commit. Don't dispatch another implementer subagent. For multi-file or behavioral changes, dispatch.

### 12. Commit conventions

- Subject: imperative mood, `<type>(sync): <summary>` format
- `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` on assistant-driven commits
- Tasks that need a follow-up fix get a separate `fix(sync): ...` commit (do NOT amend the implementer's commit)
- Never amend, never force-push, never `--no-verify`

---

## Plan-text corrections for Phases 6–10

Beyond the conventions above, several specific issues in the original plan apply downstream:

### Phase 6 (SwiftData V2)

- **Schema V1 snapshot**: the plan says "copy the V1 `Book` and `ReadingProgress` (pre-Task 6.1/6.2) definitions". Check the actual fields that existed before this work touched them. The pre-Phase-6 `Book` already has `partialMD5: String?` (from earlier kosync work). Don't re-add fields the V1 snapshot already had.
- **`Schema.Version` syntax** in newer SwiftData might differ from `Schema.Version(1, 0, 0)`. Verify against current Swift SDK version (project is Swift 5.10).

### Phase 7 (BackendFactory + SyncService)

- **AuthStore.SyncProtocol**: enum lives at top of `AuthStore.swift` (Task 7.1). The plan suggests adding `activeProtocol`, `koboBaseURL`, `koboImageURLTemplate` fields. Note that AuthStore is in **Core**, not iOSReader. The `BackendFactory` is in **iOSReader/Services** because it constructs both Core types and iOSReader-target types (OPDSClient).
- **OPDSCatalogAdapter**: adapt to the real `OPDSClient` API on the current branch. The plan's adapter code uses placeholder field names (`e.atomID`, `e.acquisitionURL`, `e.format`, `e.thumbnailURL`); the real `OPDSEntry` may use different names. Check `iOSReader/Networking/OPDSClient.swift` and `OPDSFeed.swift` first.
- **`KOSyncBackend` constructor**: requires `(client: KOSyncClient, deviceID: String, deviceName: String)`. Already exists from Task 5.1.
- **`KoboBackend` constructor**: same signature, but `KoboBackend` is an `actor` now (not a struct). All access via `await` already — should compose without issue, but make sure `BackendFactory` returns `any SyncBackend` and `any CatalogBackend` (existentials) so the protocol contract is preserved.
- **`AuthStore` persistence**: the existing AuthStore uses Keychain for credentials. The new Kobo fields (baseURL, imageURLTemplate) should follow the same pattern — Keychain for the secret-bearing base URL, UserDefaults or in-memory for the imageURLTemplate cache.

### Phase 7.4 (SyncService refactor)

The current `SyncService` is at `iOSReader/Services/SyncService.swift` and uses `KOSyncClient` directly. The refactor:
- Replace the direct `KOSyncClient` dep with `backendForProtocol: (AuthStore.SyncProtocol) -> any SyncBackend` closure
- Make all operations route through the closure's returned backend, picking the protocol from the buffered row's `pendingProtocol` field (not the *current* active protocol — protocol pinning is critical)
- The reason: a user can buffer a write under kosync, then switch to Kobo before the flush. Pinning at buffer time means the flush goes to kosync.

The original plan has the pseudocode at line ~2330 of the plan file. Trust the pseudocode; ignore plan-line specifics that drift.

### Phase 8 (LibraryService.refresh)

- Match books by `(normalised title, normalised authors)`. Normalize = lowercase + strip punctuation + strip whitespace.
- Existing books not in new catalog list → `archived = true` (kept on disk, hidden from main shelf).
- Identity merging: only fill in *missing* identity fields, never overwrite an existing one.

### Phase 9 (Settings UI)

- Use the existing Settings file structure. The current settings code uses a view model pattern — the plan's snippets are illustrative; match the actual file's structure.
- "Test connection" for Kobo validates `/v1/initialization` by parsing the response and checking that `Resources.image_url_template` exists. The plan's spec calls this out — keep the check strict.

### Phase 10 (Docs + smoke test)

- Manual smoke tests need a live CWA. The cluster at `https://cwa.example.com` is available; use the existing Kobo auth token from `kubectl exec -n calibre-web deploy/calibre-web -- sqlite3 /config/app.db "SELECT auth_token FROM remote_auth_token WHERE token_type=1 LIMIT 1;"`.
- README updates: add a "Sync protocols" section. Don't break existing README structure.

---

## Working with the existing infrastructure

### Subagent dispatch template

For each task, dispatch using:

```
Task tool (general-purpose):
  description: "Implement Task X.Y"
  prompt: <full task body from original plan + this resume file's conventions + current HEAD SHA>
```

Then per the `subagent-driven-development` skill: two-stage review (spec compliance → code quality), inline fixes for <3-line review issues, separate implementer dispatch for larger fixes.

### Skipping the second-stage review for trivial commits

If a task is **test-only** (no production code change), the spec compliance review usually suffices — code quality review is overkill. Use judgement; the skill technically requires both, but a test-only patch with green tests and a clean diff doesn't need a code-reviewer subagent. Tasks 4.2 and 5.0 in this run skipped it.

### Don't dispatch implementer subagents in parallel

They conflict on file edits. Sequential only.

### Verify timestamps and "today's date"

Date may roll forward across long sessions. Check `git log -1 --format=%cI` if you need a stable timestamp.

---

## Remaining task summary (read the original plan for full TDD steps)

From `docs/superpowers/plans/2026-05-11-multi-protocol-sync.md`:

| # | Task | Files | Notes |
|---|---|---|---|
| 6.1 | Book gains serverIDProtocol/koboBookUUID/archived | iOSReader/Models/Book.swift | Backward-compatible nullable additions |
| 6.2 | ReadingProgress gains kobo/pendingProtocol fields | iOSReader/Models/ReadingProgress.swift | Rename `progressString` → `koSyncProgressString` |
| 6.3 | SchemaV1/V2 snapshots + migration plan | iOSReader/Models/{SchemaV1,SchemaV2,AppMigrationPlan}.swift, App init | SwiftData lightweight migration |
| 6.4 | One-shot SchemaBackfill | iOSReader/Services/SchemaBackfill.swift + tests | Backfill `serverIDProtocol = "kosync"` and `pendingProtocol = "kosync"` for pre-V2 rows |
| 7.1 | AuthStore.activeProtocol + Kobo fields | Core/Sources/Core/AuthStore.swift | Persisted via existing Keychain pattern |
| 7.2 | BackendFactory | iOSReader/Services/BackendFactory.swift + tests | Returns (any SyncBackend, any CatalogBackend) |
| 7.3 | OPDSCatalogAdapter | iOSReader/Networking/OPDSCatalogAdapter.swift + tests | Wraps existing OPDSClient as CatalogBackend |
| 7.4 | SyncService backend-agnostic refactor + protocol pinning | iOSReader/Services/SyncService.swift + tests | Critical: pin protocol on buffered uploads |
| 8.1 | LibraryService.refresh via CatalogBackend | iOSReader/Services/LibraryService.swift + tests | Title+author matching, archive flag |
| 9.1 | Settings protocol picker | iOSReader/UI/Settings/SettingsView.swift | + Test connection button |
| 9.2 | Protocol switch confirmation + library refresh | Same + LibraryService | Confirmation dialog, non-destructive |
| 10.1 | README updates | README.md | Sync protocols section |
| 10.2 | Manual smoke tests | This file (append results) | 5 scenarios per spec |

13 tasks total. Estimate: ~3–5 hours of subagent execution time.

---

## How to start

1. Verify state: `cd ~/Git/ios-reader && git log -1 --oneline` should show `c211760` (or descendant).
2. Verify tests green: `make test-core` should show 78 tests passing, `make test-ios` should still pass.
3. Read the original plan at `docs/superpowers/plans/2026-05-11-multi-protocol-sync.md` — Phases 6–10 only.
4. Read this resume file's "Conventions" section before dispatching the first subagent.
5. Begin with Task 6.1 (Book model changes). Each task: dispatch implementer → spec review → code quality review → inline fix if needed → mark complete → next.

When all 13 tasks done, dispatch a final cross-cutting code review and run `make test-core && make test-ios`. The whole sync feature should pass end-to-end at that point; manual smoke (Task 10.2) is the final acceptance gate.
