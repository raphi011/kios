# iOS Reader — Protocol & Library Research

High-level research for a native Swift e-reader app (iPhone / iPad / macOS) that browses, downloads, and reads books from a self-hosted Calibre-Web instance, syncing read status and progress via the KOReader sync protocol.

---

## 1. Goals (assumed; to confirm in brainstorm)

- Native SwiftUI app, single codebase for iOS / iPadOS / macOS (Catalyst or pure SwiftUI multi-platform).
- Browse a Calibre / Calibre-Web library and download books.
- Read EPUB (and ideally PDF + CBZ) offline.
- Sync read status (started / read) and reading progress with the server, bidirectionally, KOReader-compatible.
- Self-hosted only; no cloud accounts beyond the user's server.

Open: highlights/annotations sync (out of scope of kosync — see §2.4).

---

## 2. Protocols we need to understand

Three protocols cover the full feature set. Only the first two are required for the MVP; OPDS is the easiest path to "browse + download" but Calibre-Web also has its own JSON API.

### 2.1 KOReader Sync ("kosync") — reading progress

Lightweight HTTP/JSON protocol. Stores per-user, per-document the last-known position and percentage; server returns the latest of all client uploads.

**Base content type:** `application/vnd.koreader.v1+json`
**Auth headers:** `x-auth-user`, `x-auth-key` (key = MD5 hex of password, hashed client-side)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/users/create` | Register (often disabled on shared servers) |
| `GET`  | `/users/auth` | Verify credentials |
| `PUT`  | `/syncs/progress` | Upload progress for a document |
| `GET`  | `/syncs/progress/{document}` | Fetch latest progress |
| `GET`  | `/healthcheck` | Liveness |

**Progress upload body (JSON):**
```json
{
  "document":   "<32-hex-md5>",
  "progress":   "<xpointer or page string>",
  "percentage": 0.42,
  "device":     "iPhone 15",
  "device_id":  "<stable uuid>"
}
```
- `progress` is opaque to the server — KOReader stores xpointers for EPUB, page numbers for PDF/CBZ. We need to define our own scheme that we can also resolve from KOReader's xpointers (or accept a small interop loss when the source is the other reader).
- `percentage` is 0.0–1.0.

**Server-stored fields per record:** `document`, `progress`, `percentage`, `device`, `device_id`, `timestamp`. The progress get response returns the same shape.

### 2.2 Document identification — `partial_md5_checksum` (CRITICAL)

KOReader identifies a book by a **partial-file MD5** (`Document:fastDigest()`), not a full-file MD5 and not the Calibre book ID. Two clients must produce **bit-identical** hashes for the same file or sync silently fails to match.

**Algorithm:**
```
md = MD5.new()
for i in -1 .. 10:
    offset = 1024 << (2*i)        # 256, 1024, 4096, 16384, ..., 1073741824
    seek(file, offset)
    chunk = read(file, 1024)
    if chunk is empty: break       # EOF — stop
    md.update(chunk)
hash = md.hex()                    # 32-char lowercase hex
```
Notes:
- 12 sample windows max; small files terminate early.
- KOReader has a fallback "filename" method (`md5(filename)`); the binary method is the default and the one we must implement.
- Don't trust the first README / blog hit — multiple alternative implementations shipped with hardcoded incorrect offsets. The bit-shift form is authoritative (KOReader Lua source).

### 2.3 Calibre-Web ↔ KOReader server compatibility

Two paths exist; pick one based on the user's deployment:

| Server | KOReader sync support | Endpoint base | Auth |
|---|---|---|---|
| **Calibre-Web (upstream, janeczku)** | ❌ Not native — only Kobo sync | — | — |
| **Calibre-Web-Automated (CWA fork)** | ✅ Native | `/kosync` | RFC 7617 HTTP Basic with CWA account |
| `koreader-calibre-web-sync` (vincentbitter) | ✅ Sidecar proxy in front of upstream CW | configurable | proxy-defined |
| Komga (alternative server) | ✅ Native | `/koreader` | API key (per-user, in Account Settings) |

Implications:
- If targeting upstream Calibre-Web, the user **must** run a kosync sidecar — this is a deployment decision we should surface in the README.
- CWA is the path of least resistance if the user is open to switching forks.
- Auth differs per backend: Basic auth (CWA), `x-auth-user/key` (vanilla kosync), API key (Komga). Our client should treat auth as a strategy.

### 2.4 What kosync does NOT cover

- **Highlights, notes, bookmarks** — not in the kosync protocol. KOReader devices sync these via separate community plugins (`HighlightSync`, `AnnotationSync`) using WebDAV/Dropbox. Calibre-Web has no analog today.
- **Read status as boolean ("read"/"unread")** — kosync only stores percentage. CWA's adapter marks a Calibre-Web book "Read" when percentage hits ~100%; reading that flag back requires the Calibre-Web JSON/OPDS API, not kosync.
- **Library browsing / metadata / cover art / downloads** — kosync is progress-only. Use OPDS or the Calibre-Web JSON API.

### 2.5 OPDS — catalog & download

OPDS (Open Publication Distribution System) = Atom-based feed format for browsing/downloading books. Calibre-Web exposes it at `/opds/` with HTTP Basic Auth. Two relevant versions:
- **OPDS 1.2** — Atom XML (what Calibre-Web serves).
- **OPDS 2.0** — JSON. Newer, not what Calibre-Web serves today.

For our purposes: implement OPDS 1.2 client. Pages list books with download links (`<link rel="http://opds-spec.org/acquisition" href="…">`) for each available format.

Alternative: Calibre-Web has its own JSON-ish endpoints used by the web UI. They are undocumented and unstable across versions; OPDS is a more stable contract.

### 2.6 Calibre-Web's read-status (Kobo-compat) — escape hatch

If we want true two-way "is this book read?" without depending on kosync rollover, Calibre-Web ships a **Kobo Sync** protocol. Pretending to be a Kobo device is overkill but it does carry a real read-status field. Mention only — not the recommended path.

---

## 3. Existing libraries we could use

### 3.1 EPUB / Reading

| Library | License | What it gives us | Status / Fit |
|---|---|---|---|
| **[Readium swift-toolkit](https://github.com/readium/swift-toolkit)** | BSD-3 | EPUB reflowable+fixed, PDF, CBZ, audiobook, **OPDS parser**, navigator with custom URL-scheme handler (no embedded HTTP server in v3). iOS 15+, active (v3.8.0 May 2026). | **Strongest candidate** for the rendering + OPDS layer. macOS support via Catalyst is the open question. |
| **[EPUBKit](https://github.com/witekbobrowski/EPUBKit)** | MIT | EPUB 2/3 parser only — no rendering. | Useful as a fallback or for pure metadata extraction (cover, TOC). |
| **[FolioReaderKit](https://github.com/FolioReader/FolioReaderKit)** | BSD | EPUB reader + parser. UIKit-era, less actively developed than Readium. | Older alternative; skip unless Readium falls through. |
| `iRead`, `Swift-Reader`, `EpubReaderLight` | various | Sample apps, not libraries. | Reference reading only. |

### 3.2 PDF

- **PDFKit (Apple)** — native on iOS 11+/macOS 10.4+; supports highlights, ink annotations, find, selection. No external dep. Use this for PDF.
- Readium's PDF support is also fine and consistent with its EPUB navigator.

### 3.3 CBZ (comics)

- Readium swift-toolkit supports CBZ natively.
- Otherwise: any zip lib + UIImage paging — small DIY surface if we don't take Readium.

### 3.4 OPDS

- Readium swift-toolkit absorbed `r2-opds-swift`; built-in.
- Standalone alternative: **[FeedKit](https://github.com/nmdias/FeedKit)** for raw Atom parsing + a thin OPDS layer on top (~few hundred lines).

### 3.5 KOReader sync client

**No mature Swift library exists.** Surface area is small (~5 endpoints, JSON, Basic / `x-auth-*` headers, partial-MD5 hash). Plan to write our own — straightforward URLSession + Codable + a small file-hash helper.

### 3.6 Persistence

- **SwiftData** (iOS 17+/macOS 14+) is the modern default; integrates cleanly with SwiftUI. Watch for known issues with CloudKit + SwiftData if iCloud sync ever matters (not in MVP).
- Core Data if we need older OS support.

---

## 4. Architectural sketch (subject to brainstorming)

Layered, each layer replaceable:

```
┌────────────────────────────────────────────┐
│  SwiftUI views (Library, Reader, Settings) │
├────────────────────────────────────────────┤
│  App services: Library, Sync, Downloads    │
├────────────────────────────────────────────┤
│  OPDS client │ KOSync client │ Calibre auth │
├────────────────────────────────────────────┤
│  Reader engine (Readium swift-toolkit)     │
├────────────────────────────────────────────┤
│  Storage (SwiftData) │ Files (FileManager) │
└────────────────────────────────────────────┘
```

Cross-cutting:
- **DocumentHasher** — partial-MD5 implementation, shared between Library (after download) and Sync.
- **ProgressMapper** — translates between Readium's locator and KOReader's `progress` string. Lossy in both directions; document the mapping.

---

## 5. Open questions for design

1. **Server target.** Just Calibre-Web-Automated, or also a sidecar in front of upstream Calibre-Web? Multi-server (Komga, raw KOReader sync server) optional?
2. **Format scope.** EPUB only for v1, or EPUB + PDF + CBZ from the start?
3. **Macros sync.** Read status + progress are clear. Highlights/annotations — in scope for v1, v2, or never?
4. **Offline model.** Download-on-tap and keep, or full library mirror, or LRU cache?
5. **Identity of macOS build.** Catalyst (cheap), pure multi-platform SwiftUI (cleaner), or AppKit-specific (most native)?
6. **Auth UX.** Single server config + Basic auth for both OPDS and kosync (CWA path), or separate creds per service?
7. **Conflict policy.** Kosync uses last-write-wins via timestamp. Ours probably the same; confirm.

---

## 6. Risk register

| Risk | Mitigation |
|---|---|
| Hash mismatch with KOReader | Vendor a Lua-derived test vector set; integration-test against a real `partial_md5_checksum` from KOReader. |
| Calibre-Web upstream lacks kosync | Document CWA / sidecar requirement up front; don't assume. |
| Readium toolkit's macOS story | Validate Catalyst build early — first spike. |
| `progress` xpointer round-trip fidelity | Define a stable percentage fallback; accept some drift when round-tripping with KOReader. |
| Kosync server fragmentation (vanilla / CWA / Komga) | Make auth and base URL pluggable; same RPC shape, different headers. |

---

## 7. Sources

- [koreader/koreader-sync-server](https://github.com/koreader/koreader-sync-server) — official sync server.
- [KOReader discussion #14448 — partial_md5 algorithm](https://github.com/koreader/koreader/discussions/14448).
- [KOReader kosync plugin source](https://github.com/koreader/koreader/blob/master/plugins/kosync.koplugin/main.lua).
- [nperez0111/koreader-sync](https://github.com/nperez0111/koreader-sync) — alternative server with documented endpoints.
- [DeepWiki: koreader sync API](https://deepwiki.com/dengxuezhao/koreader_sync_statistic_analysis/3.3-synchronization-api).
- [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated) — native `/kosync` endpoint.
- [vincentbitter/koreader-calibre-web-sync](https://github.com/vincentbitter/koreader-calibre-web-sync) — sidecar proxy.
- [janeczku/calibre-web issue #2122](https://github.com/janeczku/calibre-web/issues/2122) — feature-request status in upstream.
- [Komga KOReader guide](https://komga.org/docs/guides/koreader/) — alternative server target.
- [readium/swift-toolkit](https://github.com/readium/swift-toolkit) — primary reading-engine candidate.
- [witekbobrowski/EPUBKit](https://github.com/witekbobrowski/EPUBKit), [FolioReaderKit](https://github.com/FolioReader/FolioReaderKit), [nmdias/FeedKit](https://github.com/nmdias/FeedKit).
- [MobileRead OPDS wiki](https://wiki.mobileread.com/wiki/OPDS).
- Apple PDFKit documentation.
