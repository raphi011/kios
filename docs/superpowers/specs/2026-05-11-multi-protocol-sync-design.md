# Multi-Protocol Sync Backend (Design)

**Status**: Draft, awaiting plan
**Author**: rg + Claude (brainstormed 2026-05-11)
**Supersedes**: nothing — extends the v1 design at `2026-05-10-ios-reader-design.md`
**Related**: `docs/calibre-web.md` (cluster-side ops), `docs/research.md` §2 (protocol research)

## Problem

The iOS reader currently speaks one sync protocol: KOReader Sync (`kosync`)
against CWA's `/kosync` endpoint, identifying books by partial-MD5 hash. This
does not interoperate with a Kobo running stock Nickel firmware, which only
speaks Kobo's proprietary sync against CWA's `/kobo/<token>/...` blueprint.
Books read on a Kobo do not surface progress to the iOS reader, and vice
versa, because the two sync silos in CWA's `app.db` (`kosync_progress` and
`kobo_reading_state`/`kobo_bookmark`) have disjoint identifiers (file hash
vs. book UUID) and incompatible progress-location formats.

The goal is to let one user read the same book on a Kobo and on iPhone, with
read status and reading progress kept in sync, without modifying the Kobo
firmware and without running a sync-bridging service in the cluster.

## Goal

Add a second sync backend — **Kobo Sync against CWA's `/kobo/<token>` blueprint** —
behind a protocol abstraction in the iOS reader. The user picks one
protocol in Settings; the rest of the app is backend-agnostic.

Kosync mode continues to work unchanged. Switching protocols is non-destructive:
the same local library and reading-progress rows survive a switch.

## Non-goals (v1)

These are *deliberately out of scope*. They are listed so we don't drift mid-
implementation. Each has a one-line rationale.

| Excluded | Rationale |
|---|---|
| Shelves / collections (`/v1/library/tags`) in either protocol | Reading sync is the goal; shelves are organisational nice-to-have. Adds ~3-4 endpoints and a new UI surface. |
| Highlights & annotations | Neither protocol carries them in CWA today; KOReader uses WebDAV/Dropbox for this, separately. |
| Statistics upload (reading time tracking) | The Kobo blueprint accepts `SpentReadingMinutes`/`RemainingTimeMinutes` but we don't track them locally. Adds a clock and idle-detection layer. |
| OAuth refresh / `/oauth/*` endpoints | CWA's token-in-URL scheme already authenticates us; OAuth is for real-Nickel device-bound auth. |
| Kobo Store proxy mode (`config_kobo_proxy`) | We're never talking to the real Kobo store. We accept that *CWA* may proxy, which surfaces as stray entries in the sync array (handled defensively, see below). |
| Real-time / push sync | Both protocols are HTTP-poll; no server-push exists. |
| Multiple simultaneous servers | One server config at a time; mode picker swaps protocol against the same server in v1. Multi-library is a separate feature. |
| Auto-detection of which protocol a server supports | User pastes credentials per-protocol; auto-detection saves no clicks (creds differ per protocol). |
| Migration that *converts* pending kosync uploads into Kobo uploads on mode switch | Buffered uploads complete against their *original* protocol via protocol pinning; no conversion needed. |
| `DELETE /v1/library/<book_uuid>` (server-side library removal) | Useful for sign-out / cleanup but not for sync. Add later if needed. |
| Cover-only refresh path | Covers come bundled with sync responses; we don't need a separate refresh endpoint. |
| Multi-device statistics aggregation | We sync our own device's progress and surface peer progress; we don't try to be "the dashboard." |

These are revisited in v1.1+ planning.

## Architecture

### Module layout

```
Core/ (SPM, pure Foundation, fast test loop)
├── HTTPClient.swift                      (existing)
├── KeychainStore.swift                   (existing)
├── AuthStore.swift                       (existing → gains protocol-mode field)
├── DocumentHasher.swift                  (existing, kosync-only)
│
├── SyncBackend.swift                     ★ NEW: protocol + canonical types
├── CatalogBackend.swift                  ★ NEW: protocol
│
├── KOSync/                               ← move existing kosync code into folder
│   ├── KOSyncClient.swift
│   ├── KOSyncBackend.swift               ★ NEW: SyncBackend impl
│   └── KOSyncProgressMapper.swift        (rename of existing ProgressMapper)
│
└── Kobo/                                 ★ NEW folder
    ├── KoboClient.swift                  raw HTTP endpoints
    ├── KoboBackend.swift                 SyncBackend + CatalogBackend impl
    ├── KoboProgressMapper.swift          location ↔ Locator translation
    ├── KoboTypes.swift                   wire-shape Codables incl. KoboBookmarkPayload
    └── Models/BookFormat.swift           ★ moved from iOSReader/Models so that
                                          CatalogEntry can reference it

iOSReader/ (Xcode app target)
├── Models/Book.swift                     → gains koboBookUUID (nullable);
                                          → imports BookFormat from Core
├── Networking/OPDSClient.swift           (existing; used only in kosync mode)
├── Services/
│   ├── LibraryService.swift              → routes via active CatalogBackend
│   ├── DownloadService.swift             → routes via active CatalogBackend
│   ├── SyncService.swift                 → routes via active SyncBackend
│   └── BackendFactory.swift              ★ NEW: builds active pair
└── UI/Settings/                          → protocol picker + per-protocol fields
```

**Boundary rule**: the iOS app target never imports `KOSyncClient` or
`KoboClient` directly. It depends on `SyncBackend` and `CatalogBackend`
protocols and asks `BackendFactory` for the configured pair. Switching
protocols = building a different factory output.

**Catalog asymmetry**: kosync mode needs OPDS for catalog (separate dependency);
Kobo mode bundles catalog + sync in one. `KOSync` produces only a
`SyncBackend`; `Kobo` produces both. The factory wires `OPDSClient` as the
`CatalogBackend` when kosync is active.

### Core types

```swift
// Core/Sources/Core/SyncBackend.swift

/// Canonical, protocol-agnostic progress for one book on one device.
public struct CanonicalProgress: Sendable, Equatable {
    public let percentage: Double           // 0.0–1.0 overall progression
    public let locatorJSON: String?         // Readium-shaped, optional
    public let timestamp: Date              // server time, or device if backend
                                            // didn't supply one
    public let deviceID: String             // stable per-install UUID
    public let deviceName: String           // human-readable
}

/// One book's per-protocol identity. Backends accept whichever they need.
public struct BookIdentity: Sendable, Hashable {
    public let partialMD5: String?          // kosync identity
    public let koboBookUUID: String?        // Kobo identity
}

public enum BackendError: Error, Sendable {
    case identityMissing(field: String)
    case authenticationFailed
    case serverShapeUnexpected(detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(URLError)
}

public protocol SyncBackend: Sendable {
    func authenticate() async throws
    func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress?
    func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws
}
```

```swift
// Core/Sources/Core/CatalogBackend.swift

public struct CatalogEntry: Sendable, Equatable {
    public let serverID: String             // backend-specific stable ID
    public let title: String
    public let authors: [String]            // may be [] for backends that omit
    public let identity: BookIdentity       // populated as backend can
    public let downloadURL: URL
    public let format: BookFormat
    public let thumbnailURL: URL?
}

public protocol CatalogBackend: Sendable {
    func listLibrary() async throws -> [CatalogEntry]
    func resolveDownload(for entry: CatalogEntry) async throws -> URL
}
```

`CanonicalProgress.locatorJSON` is a `String` (opaque) — the Readium
`Locator` type lives in the iOS app target, not Core. The iOS app
deserialises it when applying to the navigator.

### SwiftData model changes

`Book` adds two fields; one new model is added. SwiftData lightweight migration
handles the nullable additions.

```swift
@Model final class Book {
    @Attribute(.unique) var id: UUID
    var serverID: String                    // OPDS atom:id OR Kobo EntitlementId
    var serverIDProtocol: String            // ★ NEW: "kosync" or "kobo"
    var title: String
    var authors: [String]
    var opdsHref: URL?                      // ★ NULLABLE: kosync mode only
    var acquisitionURL: URL                 // resolved at list time
    var format: BookFormat
    var filename: String?
    var partialMD5: String?                 // (unchanged)
    var koboBookUUID: String?               // ★ NEW
    var thumbnailURL: URL?
    var addedAt: Date
    var archived: Bool = false              // ★ NEW: hidden after protocol switch
                                            // when book not in new backend
    var identity: BookIdentity {
        BookIdentity(partialMD5: partialMD5, koboBookUUID: koboBookUUID)
    }
}

@Model final class ReadingProgress {
    @Attribute(.unique) var bookID: UUID
    var percentage: Double
    var locatorJSON: String?                // canonical (Readium-shaped)
    var koSyncProgressString: String?       // existing field; nullable
    var koboLocationSource: String?         // ★ NEW
    var koboLocationValue: String?          // ★ NEW
    var updatedAt: Date
    var deviceID: String
    var pendingUpload: Bool
    var pendingProtocol: String?            // ★ NEW: which backend owes the push
}
```

**Migration**: SchemaV1 → SchemaV2 is lightweight (all new fields are nullable
or have defaults). A one-shot startup task backfills two columns:

- `Book.serverIDProtocol = "kosync"` for rows where it is an empty string
  (existing installs).
- `ReadingProgress.pendingProtocol = "kosync"` for rows where
  `pendingUpload == true && pendingProtocol IS NULL` (pre-V2 buffered
  writes get pinned to their original protocol).

**Mode-switch matching**: when the user switches protocol, the new
`CatalogBackend.listLibrary()` is called. For each returned entry:

1. Match against existing `Book` by `(normalised title, normalised authors)` —
   lowercase + strip punctuation.
2. If matched: populate the missing identity field (`koboBookUUID` going to
   Kobo, or `partialMD5` going back to kosync if a local file exists to hash).
3. If not matched: insert as new `Book` with `serverIDProtocol = <new mode>`.
4. Books that exist locally but are absent from the new listing → mark
   `archived = true` (kept on disk, hidden from main shelf, restored if they
   reappear).

## Kobo Client surface (CWA `/kobo/<token>` blueprint)

All paths below are suffixes to the base URL
`https://<cwa-host>/kobo/<token>`. The token is the auth credential. No
headers or Basic auth are sent.

### Endpoints used in v1

| Method | Path | Purpose | Notes |
|---|---|---|---|
| `GET` | `/v1/initialization` | Capability discovery; `image_url_template`, `image_url_quality_template` | Cached on first auth |
| `GET` | `/v1/library/sync` | Library list + state diff | Request `x-kobo-synctoken` in, response `x-kobo-synctoken` out. Loop while response `x-kobo-sync` header equals literal `"continue"` |
| `GET` | `/v1/library/<book_uuid>/metadata` | Per-book metadata refresh (optional) | Returns `[metadata]` (single-element array) |
| `GET` | `/v1/library/<book_uuid>/state` | Fetch reading state | Returns `[ReadingState]` |
| `PUT` | `/v1/library/<book_uuid>/state` | Push reading state | Body: `{"ReadingStates": [...]}`. Response: `{"RequestResult": "Success", "UpdateResults": [...]}` |
| `GET` | URLs from `DownloadUrls[].Url` in sync response | Download a book file | URLs are CWA-built; never construct paths client-side |
| `GET` | URLs built from `image_url_template` | Cover image | Substitute `{ImageId}`, `{width}`, `{height}` |

**Not used in v1**: tags/shelves (`/v1/library/tags*`), annotations,
statistics upload, OAuth, store-browse stubs, device-registration
(`/v1/auth/device`).

### Auth model

```swift
public struct KoboServerConfig: Sendable {
    public let baseURL: URL    // e.g. https://cwa.example.com/kobo/<token>
    // No separate credentials — token is in the URL path.
}
```

The whole base URL goes into Keychain. The token is bound to a CWA user at
admin-token-issue time. Re-auth = paste a new URL.

### Wire shapes (verified against live CWA 4.0.6)

**Sync response** is a top-level **JSON array of mixed entries**:

```jsonc
[
  { "NewEntitlement": { "BookEntitlement": {...}, "BookMetadata": {...}, "ReadingState": {...} } },
  { "ChangedEntitlement": { "BookEntitlement": {...}, "BookMetadata": {...} } },
  { "ChangedReadingState": { "ReadingState": {...} } },
  { "NewTag": {...} },         // shelves — ignored
  { "ChangedTag": {...} },     // shelves — ignored
  { "DeletedTag": {...} },     // shelves — ignored
  "ResponseStatus"             // ★ stray non-dict entry — must skip
]
```

> ⚠️ **Defensively skip non-dict array entries.** A live probe against CWA
> 4.0.6 returned the literal string `"ResponseStatus"` as the last entry,
> evidently spillover from `sync_results += store_sync_results` when
> Kobo-store proxy mode is on. Codable decoder should return nil for unknown
> shapes; the parser should `compactMap` over entries.

**ReadingState shape** (verified):

```jsonc
{
  "EntitlementId": "aa672a79-3b5a-4802-8c26-0fea69d5faf3",
  "Created": "2026-05-...",
  "LastModified": "2026-05-...",
  "PriorityTimestamp": "2026-05-...",
  "StatusInfo": {
    "LastModified": "2026-05-...",
    "Status": "Reading",                   // "Reading" | "Finished" | "ReadyToRead"
    "TimesStartedReading": 1,
    "LastTimeStartedReading": "2026-05-..."  // optional
  },
  "Statistics": {
    "LastModified": "2026-05-...",
    "SpentReadingMinutes": 42,             // optional
    "RemainingTimeMinutes": 120            // optional
  },
  "CurrentBookmark": {
    "LastModified": "2026-05-...",
    "ProgressPercent": 45.0,               // 0–100; omitted when unset
    "ContentSourceProgressPercent": 16.0,  // 0–100; omitted when unset
    "Location": {                          // omitted when unset
      "Value": "kobo.10.1",
      "Type": "KoboSpan",
      "Source": "f_0035.xhtml"             // sometimes full path "OEBPS/.../chapter5.xhtml"
    }
  }
}
```

`Location.Source` heterogeneity (filename vs full path) is fine — use
as-is for the Readium `Locator.href`; Readium resolves either against the
publication.

**PUT request body**:

```jsonc
{
  "ReadingStates": [{
    "CurrentBookmark": {
      "ProgressPercent": 45.0,
      "ContentSourceProgressPercent": 16.0,
      "Location": { "Value": "kobo.10.1", "Type": "KoboSpan", "Source": "f_0035.xhtml" }
    },
    "StatusInfo": { "Status": "Reading" },
    "Statistics": { "SpentReadingMinutes": 42, "RemainingTimeMinutes": 120 }
  }]
}
```

CWA reads `request_data["ReadingStates"][0]`.

**BookMetadata** (relevant fields):

| Field | Used for |
|---|---|
| `Title` | catalog title |
| `Contributors` | catalog authors. **Shape varies**: live CWA returns a flat array of strings (`["Felienne Hermans"]`); real Kobo returns structured objects (`[{"Name": "...", "Role": "Author"}]`). Decoder accepts both, normalises to `[String]`. |
| `CoverImageId` | substitute into `image_url_template` → cover URL |
| `DownloadUrls[].Url` | direct download URL (CWA-built) |
| `DownloadUrls[].Format` | `"KEPUB"`, `"EPUB"`, `"EPUB3FL"` (fixed-layout) |
| `DownloadUrls[].Size` | byte count for progress UI |
| `EntitlementId` | book UUID (matches BookEntitlement.Id) |
| `Description`, `Language`, `Publisher`, `PublicationDate` | optional, populate if present |

`EntitlementId` from `BookEntitlement` or `BookMetadata` is the
`koboBookUUID` we store on `Book`.

### Pagination

- Request: send `x-kobo-synctoken` if we have one from a prior sync; omit
  on first sync.
- Response: read `x-kobo-synctoken` from headers, persist it for next call.
- Response: read `x-kobo-sync` header. If exactly `"continue"`, immediately
  re-call `/v1/library/sync` with the *new* token. Any other value (including
  literal `"None"` — Flask quirk) → done.

The sync token is opaque base64-encoded JSON; clients round-trip it without
parsing.

### Error mapping

| Server response | Client handling |
|---|---|
| 401 from any endpoint | `BackendError.authenticationFailed` → Settings prompts to re-enter URL; persisted config cleared |
| 404 on `PUT /state` | Re-run `listLibrary()` to refresh `koboBookUUID` mapping, retry once |
| 410 on `/library/sync` | Drop local sync token, restart from full sync |
| 429 | `BackendError.rateLimited(retryAfter)` |
| Network failure | Mark `pendingUpload = true`, retry on app foreground |
| Decoding error on known shapes | `BackendError.serverShapeUnexpected` with sample, surfaced as actionable error |

## Progress translation

### KoboProgressMapper

```swift
public enum KoboProgressMapper {

    /// Kobo → Readium-shape locator JSON. High fidelity when `value` is a
    /// koboSpan ID (KEPUB); progression-only fallback otherwise.
    public static func toLocator(
        source: String, type: String, value: String,
        progressPercent: Double, totalPercent: Double
    ) -> String {
        var locations: [String: Any] = [
            "progression": progressPercent / 100,
            "totalProgression": totalPercent / 100,
        ]
        if value.hasPrefix("kobo.") {
            locations["cssSelector"] = "#" + escapeCSS(value)
        }
        let locator: [String: Any] = [
            "href": source,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        return try! JSONSerialization.string(withJSONObject: locator)
    }

    /// Readium → Kobo. Caller has already extracted the koboSpan id (or nil).
    public static func toKoboBookmark(
        href: String, koboSpanId: String?,
        progression: Double, totalProgression: Double
    ) -> KoboBookmarkPayload {
        KoboBookmarkPayload(
            source: href,
            type: "KoboSpan",
            value: koboSpanId ?? "",
            progressPercent: progression * 100,
            contentSourceProgressPercent: totalProgression * 100
        )
    }

    /// Escape `.` so we can use a koboSpan id directly as a CSS id selector.
    /// `kobo.10.1` → `kobo\\.10\\.1`. Sufficient because koboSpan IDs only
    /// contain `[a-zA-Z0-9.]`.
    private static func escapeCSS(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }
}

/// Wire shape for `PUT /v1/library/<uuid>/state`. Lives in `KoboTypes.swift`.
public struct KoboBookmarkPayload: Codable, Sendable, Equatable {
    public let source: String
    public let type: String                  // always "KoboSpan"
    public let value: String                 // koboSpan id, or "" when unknown
    public let progressPercent: Double       // 0..100
    public let contentSourceProgressPercent: Double  // 0..100
}
```

### Extracting koboSpan from the Readium navigator

On each navigator locator change, inject JS into the rendering iframe:

```javascript
(function() {
  const el = document.elementFromPoint(window.innerWidth / 2, 0);
  if (!el) return null;
  const span = el.closest('.koboSpan');
  return span ? { id: span.id, src: location.pathname } : null;
})()
```

Returns `{id, src}` for KEPUB; nil for plain EPUB. When nil, push degraded
`(Source: <href>, Value: "", ProgressPercent: ...)` — Nickel and other clients
will reconstruct from `ProgressPercent`.

### KOSyncProgressMapper (existing, extended)

Existing wire format `"<chapter>:<intra-progression>"` is unchanged. The
mapper additionally emits a Readium-shape `locatorJSON` for canonical
storage:

```swift
public static func toLocator(
    progressString: String,
    percentage: Double,
    chapterHrefs: [String]
) -> String? {
    guard let (chapter, intra) = try? decodeProgress(progressString),
          chapter >= 0, chapter < chapterHrefs.count else { return nil }
    let locator: [String: Any] = [
        "href": chapterHrefs[chapter],
        "type": "application/xhtml+xml",
        "locations": ["progression": intra, "totalProgression": percentage],
    ]
    return try? JSONSerialization.string(withJSONObject: locator)
}
```

### Quality tiers

| File on iOS | Active protocol | Fidelity |
|---|---|---|
| KEPUB | Kobo | Sentence-level (koboSpan cssSelector) |
| KEPUB | kosync | Chapter + percentage (no koboSpan use) |
| Plain EPUB | Kobo | Percentage-only (no koboSpan to anchor) |
| Plain EPUB | kosync | Chapter + percentage (existing behavior) |

**Recommendation**: when Kobo backend is active, the CatalogBackend should
prefer `DownloadUrls[].Format == "KEPUB"` over `"EPUB"` for the iOS download.
Readium handles KEPUB transparently (it's EPUB + koboSpans).

## Conflict resolution

Last-write-wins server-side, with a UI prompt for significant divergence.

**On book open** (`SyncService.onOpen`, now backend-agnostic):

```
local  = ReadingProgress row for this Book
remote = await backend.fetchProgress(for: book.identity)

if remote == nil:                       return .useLocal
if remote.deviceID == ourDeviceID:      return .useLocal
if remote.timestamp <= local.updatedAt: return .useLocal
delta = abs(remote.percentage - local.percentage)
if delta < 0.01:                        return .useLocal
if delta > 0.05:                        return .promptUser(local, remote)
                                        return .applyServer(remote)
```

The 1%/5% thresholds account for clock skew between peer devices.

**On progress flush** (page-turn buffered → network push debounced):

```
buffered = ReadingProgress where pendingUpload == true
backend  = factory.makeBackend(for: buffered.pendingProtocol)   ★ not "current"
try:
    await backend.pushProgress(buffered.canonical, for: book.identity)
    buffered.pendingUpload = false
except identityMissing:
    listLibrary()       # populate missing ID
    retry once
except network:
    keep pendingUpload = true   # foreground retry
```

**Protocol pinning** (`pendingProtocol`) is critical: a user can buffer a
page-turn under one protocol then switch protocols before the flush. Without
pinning, the flush goes to the *current* backend with the *original*
protocol's identity — silent data loss class.

## Settings UX

Single server config per launch. Protocol picker at the top. Fields below
change with selection.

```
Settings
─────────────────────────────────────────
Server
  Protocol  [ KOReader Sync ▾ ]
            ├─ KOReader Sync (kosync)
            └─ Kobo (Calibre-Web Kobo Sync)

  ─── KOReader Sync ───
  Server URL    [ https://cwa.example.com    ]
  Username      [ admin                            ]
  Password      [ ••••••••                         ]
  [ Test connection ]

  ─── Kobo ───
  Sync URL      [ https://cwa.example.com/kobo/<token> ]
                ⓘ Get this from CWA admin →
                  Users → enable Kobo sync → copy URL
  [ Test connection ]
─────────────────────────────────────────
Library
  Last synced   5 minutes ago
  [ Refresh library ]
  [ Sign out & wipe local data ]
```

### Validation flow (Test connection)

1. Build a transient `SyncBackend` from form values without persisting.
2. Call `backend.authenticate()` — fails on 401/network/DNS.
3. For Kobo additionally: GET `/v1/initialization` and validate the response
   contains a `Resources` object with `image_url_template` — distinguishes
   "actual CWA Kobo blueprint" from "URL that 200-OKs anything."
4. On success: persist to Keychain, swap `AuthStore.activeProtocol`, refresh
   library.
5. On failure: keep the old config; show the inline error.

### Protocol switch confirmation

Non-destructive switch with confirmation sheet:

> **Switch to Kobo Sync?**
>
> Your library will refresh from `cwa.example.com/kobo/…`. Existing
> downloaded books stay on disk. Reading progress for books that match by
> title and author will carry over automatically.
>
> [ Cancel ]  [ Switch ]

No "wipe" on switch — wipe is a separate explicit action under "Sign out &
wipe local data."

## Lifecycle edges

| Scenario | Behavior |
|---|---|
| Switch protocol with pending uploads | Pending uploads complete against pinned protocol in background. New reads use new protocol. |
| Password / token rotated mid-session | Next backend call returns 401 → SyncService surfaces "re-auth needed" → Settings opens with current URL pre-filled. No silent retry loops. |
| Backend unreachable on launch | App opens in offline mode. Local library + reader work. Banner: "Offline — sync paused." |
| New mode has empty library for this user | Existing books marked `archived = true`, hidden from main shelf, accessible via "Show archived." Reading still works locally; sync paused per-book (`identityMissing`). |
| Same logical book exists as plain EPUB (kosync side) + KEPUB (Kobo side) | Different `partialMD5`; treated as two `Book` rows. Listed under **Known limitations**. |
| Sign-out & wipe | Deletes Keychain entries, all `Book` + `ReadingProgress` rows, files from `AppPaths.booksDirectory`. Modal confirmation. |

## Testing strategy

### Layer 1 — Core SPM (`swift test`, ~1s)
- `KoboClientTests` — request shaping, JSON encode/decode, pagination loop,
  sync-token round-trip, `"continue"` header detection, stray-entry tolerance
  (feed `"ResponseStatus"` and a malformed object; assert decoder skips both).
- `KoboProgressMapperTests` — round-trip vectors: koboSpan IDs ↔ locator
  cssSelector, percentage-only fallback, malformed input.
- `KOSyncBackendTests` — verify `KOSyncClient` errors map correctly into
  `BackendError`.
- `BookIdentityTests` — each backend throws `identityMissing` for its
  required field.

### Layer 2 — iOS XCTest (`xcodebuild test`, ~30s)
- `BackendFactoryTests` — correct backend built per `AuthStore.activeProtocol`.
- `LibraryServiceTests` — mode-switch matches books by `(title, authors)`,
  fills missing IDs, marks unmatched as archived.
- `SyncServiceTests` — buffer-then-flush with both backends; protocol pinning
  preserved across mode switch (regression for the silent-data-loss class).
- `MigrationTests` — V1 → V2 SwiftData migration with seed data; existing
  rows get `serverIDProtocol = "kosync"` backfill.

### Layer 3 — Manual smoke (per release)
1. Fresh install → kosync mode → add CWA creds → library populates → download
   → read → progress syncs (verify via `kosync_progress` row).
2. Fresh install → Kobo mode → paste token URL → library populates → download
   (KEPUB) → read → progress syncs (verify via `kobo_reading_state` row).
3. Existing install with kosync history → migrate to V2 → switch to Kobo
   mode → library refreshes → books match by title → resume reading →
   progress goes to Kobo.
4. Read on real Kobo device → open same book on iPhone in Kobo mode →
   "Continue from another device?" prompt at the right percentage; accept →
   reader lands within ~1 sentence (KEPUB) or ~2% (plain EPUB).
5. Read on iPhone → open on Kobo → Kobo's home reflects updated progress.

## Known limitations (v1)

- **Duplicate Book rows** when the user has BOTH protocols populated against
  the same logical book but different file formats (plain EPUB hash ≠ KEPUB
  hash). Surfaced in app's "Library" view; user can manually archive one.
  Mitigation in v1.1: title+author matching across `(partialMD5, koboBookUUID)`
  pairs to merge automatically.
- **Plain-EPUB Kobo sync is percentage-only** — no koboSpan anchors exist
  in the file. Acceptable degradation; recommendation in docs is to download
  KEPUB when Kobo mode is active.
- **CWA stray sync entries** — the array may contain non-standard items
  (string `"ResponseStatus"` observed; future versions may add more). Parser
  skips silently. No regression risk; entries we don't recognise we can't
  process anyway.
- **No author info in some sync responses** if CWA upstream changes the
  commented-out `# "Contributors":` line; today live responses include it.
  We treat `authors` as optional, defaulting to `[]`.

## Resolved questions

1. **`/v1/initialization` caching policy** — cache for the app lifetime in
   memory; persist `image_url_template` in Keychain alongside `KoboServerConfig`
   so cover URLs work offline. Refresh on protocol switch or any 401.
2. **`BackendError.serverShapeUnexpected` surfacing** — log to console at error
   level + non-blocking banner ("Server response changed unexpectedly; please
   report"). Reader and library remain usable. Never blocking-modal.

## References

- CWA source: `/app/calibre-web-automated/cps/kobo.py`, `kobo_auth.py`,
  `services/SyncToken.py` (verified against running pod, May 2026).
- `docs/research.md` §2 — original protocol research.
- `docs/calibre-web.md` (cluster repo) — operational gotchas including
  proxy-mode behavior, Kobo cert race.
- Readium swift-toolkit `Locator` reference: <https://readium.org/architecture/models/locators/>.
- KOReader kosync source for partial_md5 + xpointer schemes.
