# Feature-complete OPDS browsing — design

Status: approved · 2026-05-11
Supersedes the OPDS sections (§4.4, §4.5) of `2026-05-10-ios-reader-design.md`.
Companion plan: `docs/superpowers/plans/2026-05-11-opds-feature-complete.md` (to be written).

## 1. Why

The v1 OPDS implementation assumed a flat publication feed and merged it into SwiftData on refresh. Calibre-Web-Automated's `/opds/` is a **navigation** feed (categories: Alphabetical, Recently Added, Shelves, Magic Shelves); actual publications live one or two levels deeper, paginated via `rel="next"`. Result: empty library on first connect.

Survey of mature OPDS clients (Foliate, Thorium, KyBook 3, Marvin, KOReader, Librera, Moon+, Aldiko) shows the universal pattern is **lazy file-tree browse**, not flat mirror. The current model fights the protocol — mirroring requires arbitrary scope choices ("which subtree is canonical?") and scales poorly. This redesign aligns the client with the protocol's tree shape and brings the feature set up to parity with mature clients: OpenSearch, cover thumbnails, infinite scroll, multi-format acquisition picker.

## 2. UX shape

Three top-level tabs:

```
┌──── Browse ────┐    ┌── Browse > Recently Added ──┐
│  Recently Added│    │  Dune                       │
│  All Books   ▶ │    │  Foundation                 │
│  Shelves     ▶ │    │  ...                        │
│  Magic Shelves▶│    │  (infinite-scroll sentinel) │
└────────────────┘    └─────────────────────────────┘
   [Browse] [Downloaded ●3] [Settings]
```

- **Browse**: `NavigationStack` rooted at `<serverURL>/opds/`. Each tap on a nav row pushes another `FeedView`; each tap on a publication pushes `BookDetailView`. Search field (`searchable`) appears once the OpenSearch descriptor URL is known.
- **Downloaded**: flat list of `Book` rows where `fileURL != nil`, driven by SwiftData `@Query`. Works fully offline.
- **Settings**: existing `SettingsView`, hoisted into a tab. Sign-out lives here (see §6).

## 3. Architecture

```
RootView (TabView)
├─ BrowseRootView (NavigationStack)
│   ├─ FeedView(feedURL: URL)            ← recursive; rendered for every feed
│   └─ BookDetailView(entry: AcquisitionEntry)
├─ DownloadedRootView
│   ├─ DownloadedListView (@Query Book where fileURL != nil)
│   └─ BookDetailView(book: Book)
└─ SettingsTab (existing SettingsView)
```

Services (unchanged except OPDSClient): `DownloadService`, `SyncService`, `KOSyncClient`, `AuthStore`, `HTTPClient`.

**Deleted types**: `LibraryService`, `LibraryServiceProtocol`, `LibraryView`, `BookListItem`, `OPDSCatalog`, `OPDSEntry` (the conflated single type), `OPDSClient.makeEntry/transform` (full rewrite).

**No new service classes** beyond what the OPDS layer needs. Browse reads `OPDSClient` directly; Downloaded reads SwiftData directly. View-models are confined to a single `@Observable` per recursive feed view (`FeedLoader`).

## 4. OPDS types

`OPDSFeed` replaces `OPDSCatalog`. Entries are a sum type, forcing the UI to handle both nav and acquisition cases.

```swift
struct OPDSFeed: Sendable, Equatable {
    let title: String
    let entries: [Entry]
    let nextURL: URL?                       // rel="next"
    let searchDescriptorURL: URL?           // rel="search", type=opensearchdescription

    enum Entry: Sendable, Equatable, Identifiable {
        case navigation(NavigationEntry)
        case acquisition(AcquisitionEntry)
        var id: String { /* nav.id or pub.serverID */ }
    }
}

struct NavigationEntry: Sendable, Equatable {
    let id: String                          // atom:id
    let title: String                       // CWA's "00" rewritten to "All" at parse time
    let summary: String?
    let href: URL                           // resolved absolute URL
}

struct AcquisitionEntry: Sendable, Equatable {
    let serverID: String                    // atom:id — primary dedup key
    let title: String
    let authors: [String]
    let summary: String?
    let publishedAt: Date?
    let acquisitions: [Acquisition]         // ≥1; one per format
    let thumbnailURL: URL?                  // rel="…/image/thumbnail"
    let coverURL: URL?                      // rel="…/image"
}

struct Acquisition: Sendable, Equatable {
    let href: URL
    let mimeType: String
    let format: BookFormat
}

struct OpenSearchDescriptor: Sendable, Equatable {
    let templateURL: URL                    // contains {searchTerms}
    func resolve(query: String) -> URL?     // URL-encodes query, substitutes template
}
```

`OPDSClient` becomes an `actor` to hold the session feed cache without `@unchecked Sendable` workarounds:

```swift
actor OPDSClient: OPDSClientProtocol {
    private let http: Core.HTTPClient
    private var feedCache: [URL: OPDSFeed] = [:]
    private var searchDescriptorCache: [URL: OpenSearchDescriptor] = [:]

    func fetchFeed(url: URL) async throws -> OPDSFeed
    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor
    func invalidate(_ url: URL)
    func invalidateAll()
}

enum OPDSClientError: Error, LocalizedError {
    case notAFeed
    case malformedURL(String)
    case unsupportedAcquisition             // entry has only DRM/indirect links
}
```

Design notes embedded in the types:

- **Heterogeneous entries**: a single feed can mix nav + acquisition. CWA rarely does this, but the spec allows it and non-CWA servers do. The sum type prevents silent dropping.
- **Multiple acquisitions per entry**: today's code picks the first acquisition link and discards the rest. New code keeps all of them; `BookDetailView` renders a format picker when count > 1.
- **OpenSearch is lazy**: every feed surfaces a `searchDescriptorURL` (almost always present on root); the descriptor itself is fetched only when the user opens the search UI, then cached for the session.

## 5. UI behavior

### 5.1 `FeedView` and infinite scroll

State lives in a small `@Observable @MainActor` loader (cleaner than five `@State` vars):

```swift
@Observable @MainActor
final class FeedLoader {
    let opds: OPDSClientProtocol
    let initialURL: URL

    private(set) var title = ""
    private(set) var entries: [OPDSFeed.Entry] = []
    private(set) var nextURL: URL?
    private(set) var searchDescriptorURL: URL?
    private(set) var phase: Phase = .idle

    enum Phase { case idle, loading, loaded, loadingMore, failed(String) }

    func loadFirstPage() async
    func loadNextPage() async               // no-op if phase == .loadingMore or nextURL == nil
    func refresh() async                    // opds.invalidate(initialURL); reset; loadFirstPage
}
```

Infinite-scroll trigger is a 1-pixel sentinel `Color.clear` at the end of the list with `.onAppear { await loader.loadNextPage() }`. SwiftUI's `.onAppear` semantics dedupe naturally as long as `loadNextPage` guards on `phase == .loadingMore`.

### 5.2 Search

Lives only at the BrowseTab root (catalog-wide, not feed-scoped — matches CWA):

```swift
BrowseRootView
  .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
  .onSubmit(of: .search) { /* resolve template, push FeedView(feedURL: resolved) */ }
```

`.searchable` is attached only when the root feed exposes a `searchDescriptorURL` (the URL pulled from the feed's `rel="search"` link). The descriptor itself (the OpenSearch description document at that URL) is fetched lazily on first search submit and cached for the session inside `OPDSClient`. Submit substitutes `{searchTerms}` in the descriptor's `templateURL`, then pushes a `FeedView` onto the same NavigationStack — results render through the same code path as any other feed.

### 5.3 Browse ↔ Downloaded reconciliation

`BookDetailView` has two inits, both rendering the same body after a SwiftData lookup keyed on `serverID`:

- `BookDetailView(entry: AcquisitionEntry)` — used from Browse. On appear: fetch `Book` by `serverID`; if found, render downloaded state.
- `BookDetailView(book: Book)` — used from Downloaded.

No merge logic; one predicate.

### 5.4 Pull-to-refresh

- `FeedView` → `await opds.invalidate(initialURL); await loader.refresh()` — re-fetches first page only; pagination state resets.
- `DownloadedListView` → no-op (driven by `@Query`).

## 6. Caching, offline, sign-out

Three caches, each with a clear scope:

| Cache | Scope | Storage | Invalidated by |
|---|---|---|---|
| Feed cache (`OPDSFeed`) | session | `[URL: OPDSFeed]` in `OPDSClient` actor | pull-to-refresh; sign-out |
| Image RAM cache (`UIImage`) | session | `NSCache` with 50 MB cost limit | memory pressure (auto); sign-out |
| HTTP response cache | persistent | `URLCache.shared` (8 MB RAM + 50 MB disk) | URLCache LRU; sign-out |

**Feed contents are not persisted to SwiftData.** They go stale fast (new books, removed books); a user who wants offline access should download the book. Persisting catalog metadata would reintroduce the synchronization problem the lazy-browse model was chosen to avoid.

**Cover thumbnails need HTTP Basic auth.** `AsyncImage` uses `URLSession.shared` and can't carry the Authorization header — covers would 401 silently and show placeholders. New view `AuthenticatedAsyncImage` fetches via `HTTPClient`, caches decoded `UIImage` in `ImageMemoryCache.shared` (`NSCache`), and benefits from `URLCache.shared` for encoded-byte caching on disk.

```swift
struct AuthenticatedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let http: Core.HTTPClient
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable() }
            else { placeholder() }
        }
        .task(id: url) { /* check cache, fetch via http, cache, set image */ }
    }
}
```

`URLCache.shared` is configured once at app boot (in `iOSReaderApp.init`):

```swift
URLCache.shared = URLCache(
    memoryCapacity: 8 * 1024 * 1024,
    diskCapacity:  50 * 1024 * 1024,
    directory: nil
)
```

**Offline matrix**

| Scenario | Behavior |
|---|---|
| Browse, offline, no cached feeds | Empty list + retry banner |
| Browse, offline, cached feeds available | Renders from cache until app kill |
| Browse, online, cached feed exists | Renders cached immediately; pull-to-refresh re-fetches |
| Downloaded, offline | Fully functional |
| BookDetailView from cached entry, offline | Metadata shown; "Download" disabled with offline notice |
| Reader on downloaded book, offline | Fully functional; kosync queues unsent progress (unchanged from v1 design §4.7) |

**Sign-out**

Triggered from Settings (closing the loop on the README §"Known follow-ups"):

1. `AuthStore.clear()` (Keychain wipe)
2. `await opds.invalidateAll()`
3. `ImageMemoryCache.shared.removeAll()`
4. `URLCache.shared.removeAllCachedResponses()`
5. Delete `Book` rows where `fileURL == nil`
6. Leave downloaded files + their `Book` rows on disk (re-auth to same server re-links via `serverID`); bounce to `SettingsView`.

A future "Removed from server" badge can render on downloaded books whose `serverID` no longer resolves to a reachable feed — out of scope here, but the architecture supports it.

**Memory pressure**: `NSCache` evicts under pressure automatically; `[URL: OPDSFeed]` doesn't, but each feed is ~50 KB and a realistic session loads <100 distinct feeds (≈5 MB worst case). If this becomes a problem, swap to `NSCache` — one-file change.

## 7. Testing strategy

Per the project's existing Core/iOS split.

| Package | Tests added or rewritten |
|---|---|
| `Core/` (`swift test`) | `OpenSearchDescriptorTests` — URL template substitution + percent-encoding |
| `iOSReader/` (`xcodebuild test`) | All OPDS parsing, `FeedLoader` state machine, `OPDSClient` actor cache, `BookDetailView` reconciliation, `AuthenticatedAsyncImage` cache, sign-out flow |

**OPDS parsing fixtures** (replaces the single `calibre-web-opds.xml`):

| Fixture | Purpose |
|---|---|
| `cwa-opds-root.xml` | Root nav feed (4 subsection entries, no books) — the exact bug we fixed |
| `cwa-opds-books-letter.xml` | Letter index; "00" entry must render as "All" |
| `cwa-opds-publications-p1.xml` | 60 publications + `rel="next"` |
| `cwa-opds-publications-p2.xml` | Terminal page (no `next`) |
| `cwa-opds-with-search.xml` | Has `rel="search"` link → `searchDescriptorURL` populated |
| `cwa-opds-multi-format.xml` | One entry with EPUB+PDF+AZW3 acquisitions |
| `cwa-opds-mixed.xml` | Nav + publications in the same feed |
| `cwa-opensearch-description.xml` | OpenSearch description doc (`/opds/osd`) with `{searchTerms}` |

Fixtures are captured from the live `cwa.example.com` via the existing authenticated Chrome session; they are protocol-level XML and contain no sensitive data.

**Key parsing test cases** (illustrative; full list in the plan):

- Root: 0 publications, 4 nav entries, no `nextURL`, `searchDescriptorURL` present.
- Multi-format entry: `acquisitions.count == 3`, formats `[.epub, .pdf, .azw3]`, none dropped.
- Letter "00": title rendered as `"All"`.
- Pagination: page 1's `nextURL` resolves correctly against the source URL.

**`FeedLoader` tests** use a mock `OPDSClientProtocol`; assert append-on-loadMore, deduped concurrent triggers, refresh resets state, network failure preserves entries.

**`OPDSClient` cache tests** use `MockURLProtocol`: `fetchFeed` twice → one HTTP request; `invalidate(url)` then `fetchFeed` → two requests; `invalidateAll` empties cache.

**`BookDetailView` reconciliation** uses an in-memory `ModelContainer`, seeds a `Book` with a matching `serverID`, renders the view with a matching `AcquisitionEntry`, asserts "Read" replaces "Download".

**`AuthenticatedAsyncImage`** uses a fake `HTTPClient` request counter; two renders with the same URL → one request.

**Sign-out** seeds two `Book` rows (downloaded + catalog-only), primes caches, runs sign-out, asserts the catalog-only row is gone and downloaded row remains.

Existing tests (`KOSyncClientTests`, `HTTPClientTests`, `AuthStoreTests`, `DocumentHasherTests`, `ProgressMapperTests`) are untouched. `OPDSClientTests` is fully rewritten against the new model.

## 8. Out of scope

- OPDS 2.0 (JSON) — Foliate and Thorium dual-support; CWA serves 1.2 and most mobile clients are 1.2-only. Parser seam is preserved (sum-typed entries) so 2.0 can be added without UI changes.
- Facets — CWA does not emit them; uncommon outside library apps.
- DRM / indirect acquisition — CWA is DRM-free; `unsupportedAcquisition` error stub is in place for non-CWA targets later.
- Borrow / hold / subscribe acquisition relations — library-app territory.
- Persistent feed cache across launches — not needed; pull-to-refresh is cheap.
- Multiple library servers — explicitly out of scope per the v1 design.
- macOS app — deferred per the v1 design.

## 9. Migration

`feat/v1` is pre-release with no users in the wild. No migration code is added. Stale `Book` rows with `fileURL == nil` (catalog-mirror rows from the old `LibraryService`) are invisible to the new UI; dev installs can wipe simulator app data to reach a clean state.
