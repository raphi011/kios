# KEPUB koboSpan Extraction — Implementation Plan

> **For agentic workers**: REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (recommended). This is a self-contained implementation plan — read it top-to-bottom before dispatching anything.

**Date**: 2026-05-12
**Branch**: continues `feat/v1` of `~/Git/ios-reader`
**Most recent HEAD when planned**: `f37c9d9` (`fix(sync): Kobo state-update requires Location + explicit Statistics null`)

## Background

iOS sync of reading progress to Kobo (via CWA) currently works end-to-end — chapter location syncs correctly via the bookmark's `Source` field. But the `Location.Value` (the koboSpan id like `kobo.10.1`) is a **placeholder** `kobo.0.0` whenever the Readium locator that triggered the push has no `cssSelector`. That's the common case: every page-turn and scrub emits a Readium locator with `href + progression + position + totalProgression` but no cssSelector — Readium doesn't auto-extract koboSpan ids from KEPUB markup.

The downstream consequence: a real Kobo device that fetches an iOS-pushed bookmark will land in the correct **chapter** (Source is honored) but **not at the precise within-chapter position** (`kobo.0.0` isn't a real DOM element on a Kobo, so the device falls back to the chapter start). The percentages still round-trip exactly, but the bookmark navigation is degraded.

Two existing fixes are already in place on `feat/v1`:
- **commit `f37c9d9`** (`fix(sync): Kobo state-update requires Location + explicit Statistics null`) — makes the push wire-format CWA-compliant and synthesizes the `kobo.0.0` placeholder.
- **commit `601860d`** (`feat(reader): interactive scrub bar + cross-device continue navigation`) — adds the scrub UX and Continue-button navigation that motivate this work.

This plan makes the placeholder real.

## Goal

When iOS pushes a Kobo bookmark, the `Location.Value` should be an **actual koboSpan id present in the KEPUB DOM** for the current chapter, chosen to be at or near the user's within-chapter `progression`. Real Kobo devices then navigate to the exact span the user was on.

## Background: What koboSpans look like

KEPUB files are EPUB3 zip archives whose XHTML content has been augmented with `<span class="koboSpan" id="kobo.X.Y">…</span>` wrappers around the text. The id format is `kobo.<element>.<run>`:
- `<element>` is the index of the paragraph / heading / block-level element (1-based, monotonic in document order).
- `<run>` is the index of the text run within that element (1-based, monotonic).

So a chapter typically has `kobo.1.1`, `kobo.1.2`, …, `kobo.2.1`, `kobo.2.2`, … in document order. The exact numbering depends on the KEPUB-isation pipeline (`kepubify` is the most common).

A real Kobo device reads from server, sees `Location.Value = "kobo.X.Y"`, looks up the element by id, scrolls to it. If the id doesn't match any element in the DOM, behavior is firmware-specific — often a silent fall-back to the chapter start.

## High-Level Approach

1. **Open the local .epub as a ZIP**, read the chapter file referenced by the locator's `href`.
2. **Parse the XHTML**, find all `koboSpan` elements in document order.
3. **Pick the koboSpan at index `floor(progression * spanCount)`** — a linear approximation that matches the way Readium positions are roughly linear in text.
4. **Inject the resulting id into the locator's `cssSelector` field** before the push fires, so `KoboBackend.buildBookmark` (which already extracts `koboSpan` from `cssSelector`) emits it as `Location.Value`.
5. **Cache per chapter href** so the second push within the same chapter doesn't re-parse the XHTML.

## Architecture

```
SyncService.flushPendingProgress (iOS-side, MainActor)
  │
  ├── reads ReadingProgress.locatorJSON for the pending row
  │
  ├── if activeProtocol == .kobo AND locator has no cssSelector:
  │     │
  │     ├── KEPUBSpanResolver.resolve(fileURL, href, progression)
  │     │     │
  │     │     ├── ZIPReader.read(fileURL: at: href)  -> String?
  │     │     ├── KoboSpanParser.spans(in: xhtml)   -> [String]   (pure)
  │     │     └── pick spans[floor(progression * spans.count)]
  │     │
  │     └── augment locatorJSON with cssSelector: "#kobo\\.X\\.Y"
  │
  └── pushProgress(augmented canonical, ...)
```

**Layering:**
- **`Core/Sources/Core/Kobo/KoboSpanParser.swift`** — pure: takes XHTML String, returns `[String]` of koboSpan ids in document order. Unit-tested with fixture XHTML.
- **`iOSReader/Services/KEPUBSpanResolver.swift`** — `@MainActor` actor that owns the file I/O (open ZIP, read chapter), holds the per-chapter cache, and combines `KoboSpanParser` with progression-index selection.
- **`iOSReader/Services/SyncService.swift`** — calls the resolver in `flushPendingProgress` before push. Resolver is injected via a closure (so tests can stub it) or via a new constructor parameter.

The Core layer stays pure — no file I/O, no Readium dependency. iOS owns the storage details.

## ZIP Library Choice

Readium's swift-toolkit already vends a ZIP implementation (used by `AssetRetriever`), but it's not directly callable from outside Readium's publication-opening pipeline. Two practical options:

| Option | Pros | Cons |
|---|---|---|
| **ZIPFoundation** (SPM package) | Battle-tested, async-friendly, ~3kLOC, BSD-2 | New dependency to add to Core/iOSReader |
| Use Readium's already-open `Publication` instance | No new dependency; aligns with how the reader opens the file | The publication is only open while the reader is active; flush can fire when the reader is closed |

**Recommendation: ZIPFoundation.** The resolver needs to run on flush (which can fire after the reader is dismissed), so it can't depend on a live `Publication`. ZIPFoundation is the smallest delta and decouples sync from the reader lifecycle.

Add to `Core/Package.swift` (resolver wrapper lives in iOSReader, but the parser is pure-Swift in Core and doesn't need ZIPFoundation). Actually re-reading: only iOSReader needs ZIPFoundation. Add to the iOS target via SPM, not to Core.

## File-by-File Plan

### Core changes

**`Core/Sources/Core/Kobo/KoboSpanParser.swift`** (new, pure):

```swift
public enum KoboSpanParser {
    /// Returns all koboSpan ids in document order. Matches
    /// `<span class="koboSpan" id="kobo.X.Y">`. Empty if none found.
    public static func spans(in xhtml: String) -> [String]

    /// Picks the span at `floor(progression * spans.count)`. Returns nil if
    /// `spans` is empty.
    public static func span(at progression: Double, in spans: [String]) -> String?
}
```

Implementation can use `NSRegularExpression` against the XHTML. KEPUBs are produced by `kepubify` which emits a consistent shape: `<span class="koboSpan" id="kobo.N.M">`. Regex pattern `class="koboSpan"[^>]*id="(kobo\.\d+\.\d+)"` is robust to attribute reordering.

Edge cases:
- `id` and `class` in either order → use a two-pass regex or accept both attribute orders.
- Self-closing or non-span elements with `koboSpan` class — unlikely but ignore via `<span` prefix.
- Multiple spans with same id — keep first.

**`Core/Tests/CoreTests/KoboSpanParserTests.swift`** (new):

Cover:
- `spans(in:)` extracts ids in document order from a fixture.
- `spans(in:)` returns empty for XHTML without koboSpans (plain EPUB).
- `spans(in:)` handles attribute ordering: `id="kobo.1.1" class="koboSpan"` and the reverse.
- `span(at: 0.0, in: [...])` returns first.
- `span(at: 1.0, in: [...])` returns last.
- `span(at: 0.5, in: [...])` returns middle element.
- `span(at: anything, in: [])` returns nil.

Fixture: ~50-line XHTML snippet with 10 koboSpans at known positions, inline in the test.

### iOSReader changes

**`iOSReader.xcodeproj` (via XcodeGen `project.yml`)** — add ZIPFoundation as an SPM dependency. Check the existing `project.yml` for the dependency list format. Pin to a recent version (>=0.9).

**`iOSReader/Services/KEPUBSpanResolver.swift`** (new):

```swift
@MainActor
final class KEPUBSpanResolver {
    /// Per-chapter cache: keyed by (bookFileURL, chapterHref). Once resolved,
    /// the span list survives until the resolver is deallocated — chapters
    /// don't change without a fresh download. Stays in-memory only; restart
    /// re-parses on first need.
    private var cache: [Key: [String]] = [:]

    private struct Key: Hashable {
        let bookFile: URL
        let chapterHref: String
    }

    /// Returns a real koboSpan id near `progression` (0-1) within the chapter
    /// at `chapterHref` inside the KEPUB at `bookFileURL`. nil when the file
    /// can't be opened, the chapter isn't in the archive, or the chapter has
    /// no koboSpans (plain EPUB).
    func resolve(bookFileURL: URL, chapterHref: String, progression: Double) async -> String?
}
```

Implementation:
1. Build `Key`. If cached, use `KoboSpanParser.span(at: progression, in: cache[key])`.
2. Otherwise, open the ZIP via ZIPFoundation. Locate the chapter entry by suffix-match on `chapterHref` (the locator's href may be `f_0035.xhtml` while the ZIP entry is `OEBPS/text/f_0035.xhtml` — suffix-match is robust).
3. Read the entry's bytes, decode UTF-8.
4. `KoboSpanParser.spans(in: xhtml)` → array.
5. Cache, then `KoboSpanParser.span(at:in:)`.

File I/O is on a background queue inside the actor. The result is bounced back to the caller's actor context.

**`iOSReader/Services/SyncService.swift`** — extend `flushPendingProgress`:

Add an optional dependency:
```swift
let spanResolver: KEPUBSpanResolver?
```

(Constructed in `AppEnvironment` and passed in; nil-able for tests.)

In `flushPendingProgress`, after building the `canonical` but before `backend.pushProgress(canonical, …)`:

```swift
let augmented: CanonicalProgress
if proto == .kobo, let resolver = spanResolver,
   let json = canonical.locatorJSON,
   let url = book.fileURL,
   let spanID = await resolveSpanID(json: json, fileURL: url, resolver: resolver) {
    augmented = canonical.withLocatorJSON(injectingCSSSelector: spanID, into: json)
} else {
    augmented = canonical
}
try await backend.pushProgress(augmented, for: book.identity)
```

Helpers (in SyncService):
- `resolveSpanID(json:fileURL:resolver:) async -> String?` — parses the locator JSON for `href` and `progression`, calls the resolver.
- An extension on `CanonicalProgress` (or a free helper) that takes a JSON string and a span id, parses, sets `locations.cssSelector = "#kobo\\.X\\.Y"` (with the CSS escape on the dot), re-serializes, and returns a new `CanonicalProgress`.

The CSS escape: see `KoboProgressMapper.escapeCSS` in Core — already does `.` → `\.`. Reuse it; don't re-implement.

**`iOSReader/App/AppEnvironment.swift`** — construct the resolver once at init, pass into `SyncService`.

### Tests

**`iOSReaderTests/Services/KEPUBSpanResolverTests.swift`** (new):
- Fixture KEPUB: a tiny .epub zip with one chapter file containing 10 known koboSpans. Check it into `iOSReaderTests/Fixtures/` (or generate at test setup via ZIPFoundation).
- `resolve` returns the expected span for `progression = 0.0, 0.5, 1.0`.
- `resolve` returns nil for a chapter with no koboSpans.
- `resolve` returns nil for a nonexistent chapter href.
- Cache hit: second call doesn't re-open the ZIP (verify by mutating the cache or by timing).

**`iOSReaderTests/Services/SyncServiceTests.swift`** — extend existing tests:
- Inject a stub `KEPUBSpanResolver` that returns a known id.
- Assert the pushed `CanonicalProgress.locatorJSON` includes `cssSelector: #kobo\.X\.Y`.
- Assert when the resolver returns nil (plain EPUB), the locator is unchanged and the existing `kobo.0.0` placeholder still flows through `KoboProgressMapper.toKoboBookmark`.

### Acceptance Criteria

1. **iOS push → CWA**: bookmark `Location.Value` is a real koboSpan id (not `kobo.0.0`) when the book is a KEPUB. Verify by curl:
   ```
   kubectl exec -n calibre-web deploy/calibre-web -- sqlite3 /config/app.db \
     "SELECT location_value FROM kobo_bookmark ORDER BY last_modified DESC LIMIT 1;"
   ```
2. **CWA → Kobo device**: real Kobo device pulls the bookmark and navigates to the exact span (not just chapter start). Manual smoke.
3. **Plain EPUB fall-through**: a non-KEPUB book pushes with `kobo.0.0` placeholder (unchanged from today). Verified by stub-resolver test.
4. `make test-core` and `make test-ios` both green.

## Conventions (carry from prior session)

- **No backwards-compatibility shims** — `feat/v1` is pre-release; update all call sites when adding the `spanResolver` parameter to `SyncService.init`.
- **`.serialized` test suites** when touching `MockURLProtocol.handler` (Core only, doesn't apply here).
- **`.distantPast` for missing timestamps**, never `Date()`.
- **Imperative commit subjects** `<type>(sync): <summary>`. Trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` on assistant-driven commits.
- **No `--no-verify`, no amend, never force-push.**
- **Inline small review fixes (<3 lines)**; dispatch subagents for multi-file / behavioral fixes.

## Out of Scope (defer to follow-up)

- **CFI-style locators**: a more precise scheme than koboSpan, used by some EPUB readers. Kobo doesn't speak CFI.
- **Refreshing the cache when the .epub on disk changes**: current cache is in-memory and resets on app restart, which is fine for v1.x.
- **Optimizing for huge chapters**: if a chapter has >10k koboSpans, the regex pass is still <100ms on a modern device. Don't preempt-optimize.
- **Multi-chapter scrubs across chapter boundaries**: the resolver looks at one chapter at a time. Cross-chapter scrubs are already handled by the existing `pendingJump` plumbing — Readium navigates to the new chapter's `href` and progression, and the next push resolves a span in that new chapter.

## How to start the next session

```text
Continue from docs/superpowers/plans/2026-05-12-kepub-kobospan-extraction.md
Use superpowers:subagent-driven-development. Start with the KoboSpanParser
(Core, pure) since it's the smallest testable unit; layer iOSReader resolver
on top; wire SyncService last.
```

The plan is self-contained — no need to read the prior handoff doc except for the CWA setup details (cluster commands etc.) which are in `2026-05-12-post-phase-10-next-steps.md` § "Cluster + simulator quick reference".
