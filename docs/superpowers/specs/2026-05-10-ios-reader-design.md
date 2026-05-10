# iOS Reader — v1 Design

Native Swift e-reader for iPhone and iPad that browses, downloads, and reads books from a self-hosted Calibre-Web-Automated (CWA) server, syncing reading progress via the KOReader sync ("kosync") protocol.

Companion to: `docs/research.md` (protocol & library research).

---

## 1. Decisions locked in (from brainstorm 2026-05-10)

| | |
|---|---|
| Server target | Calibre-Web-Automated (CWA), `/opds/` + `/kosync` on the same host |
| Auth | HTTP Basic, single credential, both endpoints |
| Formats v1 | EPUB, PDF, CBZ |
| Reading engine | Readium swift-toolkit 3.x |
| Platforms v1 | iPhone, iPad |
| macOS | **Deferred** (not v1; revisit later) |
| Annotations | **Out** (none in v1) |
| Offline model | Download-on-tap, keep until manually removed |
| Cross-device sync source of truth | **Calibre-Web server** — kosync. **Not iCloud / CloudKit.** |
| Min OS | iOS 17 / iPadOS 17 |

### Rationale highlights

- **CWA chosen over upstream Calibre-Web** because CWA ships native `/kosync` with HTTP Basic. Upstream `janeczku/calibre-web` has only Kobo sync; supporting it would force a sidecar deployment we don't want to assume.
- **Readium chosen** despite injecting JS into its WKWebView — the alternative is writing our own EPUB renderer + locator system, which research showed even Yomu (a leading commercial native reader) doesn't do. Yomu also uses WebKit + Mac Catalyst.
- **macOS deferred** because Readium's Navigator is UIKit-only. Three real macOS paths exist (Catalyst, custom WKWebView+CSS reader, NSAttributedString-only) and the choice is best made after the iOS app is real.
- **No iCloud** — the kosync server already provides cross-device sync. Adding CloudKit creates a second sync mechanism and a conflict-resolution problem that solves nothing.

---

## 2. Stack

| Layer | Choice |
|---|---|
| UI | SwiftUI |
| Reader engine | Readium swift-toolkit 3.x (BSD-3) |
| Reader views | Readium `*NavigatorViewController` wrapped via `UIViewControllerRepresentable` |
| Networking | `URLSession` + `async/await`, native |
| Auth storage | Keychain |
| Persistence | SwiftData (local cache only — not the source of truth) |
| Files | `FileManager` under `Application Support/ios-reader/books/`, excluded from iCloud backup |
| Hashing | Custom `DocumentHasher` matching KOReader's `partial_md5_checksum` |

No third-party dependencies beyond Readium.

---

## 3. Module map

```
┌──────────────────────────────────────────────────────────────┐
│  Views (SwiftUI)                                             │
│  LibraryView · BookDetailView · ReaderView · SettingsView    │
└─────────────────────────────┬────────────────────────────────┘
                              │ ObservableObject services (protocols)
┌─────────────────────────────▼────────────────────────────────┐
│  Services                                                    │
│  LibraryService · DownloadService · SyncService · AuthStore  │
└──────┬───────────┬──────────────────┬──────────────┬─────────┘
       │           │                  │              │
   ┌───▼────┐ ┌────▼─────┐    ┌───────▼────────┐ ┌───▼────────┐
   │ OPDS   │ │ HTTP     │    │ KOSyncClient   │ │ Keychain   │
   │ Client │ │ Download │    │ (custom)       │ │            │
   └────────┘ └──────────┘    └────────────────┘ └────────────┘
       │           │                  │
   ┌───▼───────────▼──────────────────▼────────────┐
   │  SwiftData store + FileManager                │
   └────────────────────────────────────────────────┘
              │
   ┌──────────▼──────────────────┐
   │  DocumentHasher              │
   └──────────────────────────────┘
```

Each service exposes a protocol; views depend on protocols, not concrete types. Services are constructed at app start and injected through SwiftUI's environment.

---

## 4. Components

### 4.1 `KOSyncClient` (custom, ~200 LOC)

```swift
struct KOSyncClient {
    let baseURL: URL                       // e.g. https://cwa.example.com/kosync
    let auth: KOSyncAuth                   // .basic(username, password)

    func authenticate() async throws -> Bool
    func putProgress(_ p: ProgressUpload) async throws
    func getProgress(documentHash: String) async throws -> ProgressDownload?
}

enum KOSyncAuth {
    case basic(username: String, password: String)        // CWA path
    case kosyncLegacy(username: String, passwordMD5: String) // x-auth-user/x-auth-key
}

struct ProgressUpload {
    let document:   String   // 32-hex partial_md5_checksum
    let progress:   String   // chapter index + intra-chapter percentage, encoded
    let percentage: Double   // 0.0–1.0 over the whole book
    let device:     String   // UIDevice.current.name (sanitised)
    let deviceID:   String   // stable UUID per install (UserDefaults)
}

struct ProgressDownload {
    let document, progress, device, deviceID: String
    let percentage: Double
    let timestamp: Date
}
```

Endpoint shapes: see `docs/research.md` §2.1.

The legacy header form is implemented behind the same client to leave the door open for non-CWA targets without restructuring; v1 only exercises the `.basic` path.

### 4.2 `DocumentHasher` (custom, ~30 LOC)

```swift
enum DocumentHasher {
    /// KOReader binary partial_md5_checksum.
    /// Reads up to 1024 bytes at offsets 1024 << (2*i) for i in -1...10,
    /// concatenated through MD5, returns 32-char lowercase hex.
    static func partialMD5(of url: URL) throws -> String
}
```

This must be byte-identical to KOReader's `Document:fastDigest()`. Test against fixtures captured from a real KOReader install (see §8).

### 4.3 `ProgressMapper`

Bridges Readium `Locator` ↔ kosync `progress` string.

**Outgoing (our app → server):**
- Encode as `"<chapter-index>:<progression-within-chapter>"`, e.g. `"5:0.4231"`.
- `percentage` = Readium's `Locator.locations.totalProgression`.

**Incoming (server, possibly written by KOReader):**
- If `progress` matches our format, decode and seek to the exact position.
- If `progress` is a KOReader xpointer (starts with `/body/DocFragment` or similar), best-effort: parse out the fragment index, seek to that chapter, intra-chapter position falls back to `percentage * book length` mapped via Readium's `PositionList`.
- Document the lossy direction in code comments.

### 4.4 `OPDSClient`

Thin wrapper around Readium's `OPDSParser` (OPDS 1.2 / Atom). HTTP Basic auth header on every request. Returns simplified models for the UI; doesn't expose Readium types upward.

### 4.5 `LibraryService`

- Single source of truth in-process for the library list.
- Merges OPDS feed (when online) with `Book` rows in SwiftData.
- Each book has a state: `.remote`, `.downloading(progress)`, `.downloaded`, `.failed`.
- Refresh on app foreground + manual pull-to-refresh.

### 4.6 `DownloadService`

- `URLSession` background config; survives app kill.
- On finish: atomic move to books dir → compute partial-MD5 → upsert SwiftData → notify `LibraryService`.
- Throttle parallelism (max 2 concurrent downloads).

### 4.7 `SyncService`

Lifecycle hooks:

| Trigger | Action |
|---|---|
| `ReaderView.task` (open book) | `getProgress(hash)`. If server progress is **>1% ahead** of local AND from a different `deviceID`, prompt user before jumping. Otherwise apply silently. (1% threshold tunable; chosen to ignore noise from rounding while still catching cross-device reads.) |
| Locator change while reading | Buffer; flush every 30s and on chapter boundary. |
| App backgrounding while reading | Final flush. |
| `ReaderView` disappear | Final flush. |

Conflict policy: **last-write-wins by server timestamp** — matches kosync semantics. We don't try to be cleverer.

Failure mode: progress writes are best-effort. On network error we keep the unflushed update in memory + persist in SwiftData with a `pending: true` flag, retry on next foreground.

### 4.8 `AuthStore`

Wraps Keychain reads/writes for `(serverURL, username, password)`. Single account in v1.

---

## 5. Storage schema (SwiftData — local cache)

```swift
@Model class LibraryServer {
    var id: UUID
    var url: URL
    var username: String          // password in Keychain
    var lastValidatedAt: Date?
}

@Model class Book {
    var id: UUID                  // local id
    var serverID: String          // OPDS entry id from CWA
    var title: String
    var authors: [String]
    var opdsHref: URL             // catalog entry
    var acquisitionURL: URL       // direct download
    var format: BookFormat        // .epub, .pdf, .cbz
    var fileURL: URL?             // nil if not downloaded
    var partialMD5: String?       // populated after download
    var addedAt: Date
}

@Model class ReadingProgress {
    var bookID: UUID
    var locatorJSON: String       // Readium Locator JSON
    var percentage: Double
    var updatedAt: Date
    var deviceID: String
    var pendingUpload: Bool       // true if not yet pushed to server
}

@Model class Download {
    var bookID: UUID
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    var error: String?
}
```

Keychain holds the password — never SwiftData.

`Application Support/ios-reader/books/<partialMD5>.<ext>` for downloaded files. The hash-as-filename means the file is its own identity; we can recover state by re-scanning the directory if SwiftData is wiped.

---

## 6. Settings & first-run

- `SettingsView`: server URL, username, password.
- "Test connection" button calls both `GET /opds/` and `GET /kosync/users/auth`.
- Failure messages are actionable:
  - 401 on either → "Wrong username or password."
  - 200 on `/opds/`, 404 on `/kosync/users/auth` → "Your server doesn't ship kosync. iOS Reader requires Calibre-Web-Automated. See README for migration."
  - Network error → "Can't reach server. Check URL and network."

---

## 7. What's explicitly out of v1

- macOS app (revisit after iOS is real)
- Highlights / notes / bookmarks (none — kosync doesn't carry them anyway)
- Search-in-book (Readium provides API; UI deferred)
- Multiple library servers
- Audiobooks
- DRM (LCP)
- Custom themes beyond light/dark/sepia
- iCloud sync of app state — **kosync IS our sync**, no parallel mechanism
- Background app refresh for proactive sync

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Hash mismatch with KOReader → silent sync failures | Vendor a small fixture set of `(filename, expected partial_md5)` captured from a real KOReader install. Unit-test `DocumentHasher` against them on every CI run. |
| Readium minor versions change Navigator API | Pin Readium to a known-good minor; review release notes before bumps. |
| `progress` field round-trip loss (KOReader xpointer ↔ ours) | Treat `percentage` as the lingua franca for cross-reader sync. Within our own ecosystem the format is exact. Document the limitation. |
| Background download tasks on iOS are flaky | Keep a foreground retry path; surface failures explicitly in UI. |
| User deploys upstream Calibre-Web by mistake | Test-connection flow detects this and shows actionable error (§6). |

---

## 9. Next steps

1. User reviews this spec.
2. On approval, move to `superpowers:writing-plans` skill to produce an implementation plan with concrete milestones, test-first ordering, and a Catalyst/macOS spike at the end of v1.
