# Multi-Protocol Sync — Post-Phase-10 Next Steps

> **For agentic workers**: REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (recommended). This is a handoff doc — read it top-to-bottom before dispatching anything.

**Date**: 2026-05-12
**Previous context**: Phases 0–10 of the multi-protocol sync work are complete on `feat/v1`. Bonus Task 11.1 unified Browse → Library. Bonus Task 7.5 fixed the kosync wire format. A patched CWA fork is deployed in the homelab.

## Current state snapshot

### iOS Reader (`~/Git/ios-reader`)

- **Branch**: `feat/v1`
- **HEAD**: `af58585` (`fix(sync): Library refresh works on empty state + toolbar button`)
- **15 commits ahead** of the original baseline `eba8076`
- **Tests**: `make test-core` = 91 passing, `make test-ios` = 76 passing, all green
- **Build artifact for sim**: `~/Library/Developer/Xcode/DerivedData/iOSReader-fainspluzqcdgkahlssrfmuegbnu/Build/Products/Debug-iphonesimulator/iOSReader.app`

### CWA patched fork (`~/Git/Calibre-Web-Automated`)

- **Branch**: `multidevice-sync-fix` off `v4.0.6` tag
- **HEAD**: `d203344`
- **Deployed image**: `homelab.example.com/calibre-web-automated:v4.0.6-multidevice-sync.2`
- **Active in cluster**: yes (rollout completed, see `kubectl get pods -n calibre-web`)
- **Fix details**: see `docs/cwa-fork-multidevice-sync.md` in the iOS reader repo

### Simulator state

- **UDID**: `FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22` (iPhone 17)
- **App**: installed, may need fresh data via `xcrun simctl uninstall <UDID> me.iosreader.iOSReader`
- **Keychain quirk**: simctl uninstall preserves keychain. To fully reset auth state: `xcrun simctl erase <UDID>` (nukes everything).

### What works end-to-end today

- KOReader Sync (kosync) credentials → OPDS catalog → download → reader → progress sync. Verified by 76 iOS test cases + smoke testing in earlier sessions.
- Kobo Sync settings UX: protocol picker, Test & Save, library populates against the patched CWA.
- Protocol pinning: unit-test verified (`bufferThenSwitchProtocolStillFlushesToOriginalBackend`).
- Library tab: unified across protocols, pull-to-refresh + toolbar refresh button.

### What's broken/missing

- **Kobo book reading** — tapping a catalog-only Kobo book in Library shows "Kobo reading not yet supported in v1" alert. Three pieces missing (see Task A below).
- **Manual smoke tests** — checklist appended to original plan (`docs/superpowers/plans/2026-05-11-multi-protocol-sync.md` § "Smoke test checklist (Task 10.2 execution)"), execution pending.
- **CWA `else` branch fix** — full-library sync mode (when `kobo_only_shelves_sync = 0`) still infinite-loops after Alt 2. Not deployed but the patch is incomplete here. See `docs/cwa-fork-multidevice-sync.md` § "What's still broken in the fork".
- **CWA upstream PR** — not yet filed.

## Tasks, in priority order

### Task A: Wire Kobo book downloads + reading (the big one)

**Why first**: this is the gap between "library list works" and "you can actually open a Kobo book". Until this lands, the cross-device Kobo sync flow can't be exercised end-to-end (you can fetch state on book-open, but you can't open a book to test it).

**Three sub-tasks**:

#### A.1 — Make `DownloadService` work without Basic auth

`iOSReader/Services/DownloadService.swift` currently hard-codes `credentials: BasicCredentials` and bakes `Authorization` into `httpAdditionalHeaders`. Kobo's pre-signed CDN URLs require **no** auth header (sending one would break the signature).

Change:

```swift
// in DownloadService
private var credentials: BasicCredentials?   // was: non-optional

init(context: ModelContext, credentials: BasicCredentials?) {
    // unchanged otherwise
}

private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: "me.iosreader.downloads")
    config.sessionSendsLaunchEvents = true
    if let credentials {
        config.httpAdditionalHeaders = ["Authorization": credentials.authorizationHeader]
    }
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
}()

func update(credentials: BasicCredentials?) {
    self.credentials = credentials
    // recreate the session if credentials switched between nil/non-nil?
    // — for v1, simplest: leave the existing session and assume callers
    // don't change auth modes mid-process. AppEnvironment rebuild handles it.
}
```

Update all call sites — `AppEnvironment.bootIfCredentialsPresent` for kosync path passes `creds.basic` as today; for Kobo path passes `nil`.

#### A.2 — Construct `DownloadService` in Kobo mode

In `AppEnvironment.bootIfCredentialsPresent`, the `case .kobo` branch currently doesn't build a DownloadService. Add the construction (mirroring kosync's pattern):

```swift
case .kobo:
    // ... existing self.opds = nil + sync setup ...
    if let existing = self.downloads {
        existing.update(credentials: nil)
    } else {
        self.downloads = DownloadService(context: modelContext, credentials: nil)
    }
```

#### A.3 — Route Kobo tap through `resolveDownload` + reader

`iOSReader/Views/LibraryRootView.swift:handleTap` — replace the Kobo-not-supported alert with a real download path:

```swift
private func handleTap(_ book: Book) {
    if book.filename != nil {
        env.openReader(book.id)
        return
    }
    // Catalog-only — kick off download for either protocol.
    Task {
        // For Kobo, the acquisitionURL captured at listLibrary time may be
        // a pre-signed CDN URL that has expired. Refresh via the catalog
        // backend before downloading.
        if book.serverIDProtocol == SyncProtocol.kobo.rawValue {
            await refreshKoboDownloadURL(for: book)
        }
        _ = try? await env.downloads?.download(book: book)
    }
    env.openReader(book.id)  // shows downloading state until file lands
}

private func refreshKoboDownloadURL(for book: Book) async {
    do {
        let name = await UIDevice.current.name
        let (_, catalog) = try BackendFactory.build(
            auth: env.authStore, deviceID: env.deviceID, deviceName: name
        )
        // Construct a CatalogEntry to satisfy resolveDownload — we only
        // need the identity + downloadURL for the call.
        let entry = CatalogEntry(
            serverID: book.serverID,
            title: book.title,
            authors: book.authors,
            identity: book.identity,
            downloadURL: book.acquisitionURL,
            format: book.format,
            thumbnailURL: book.thumbnailURL
        )
        let fresh = try await catalog.resolveDownload(for: entry)
        book.acquisitionURL = fresh
        try? env.modelContext.save()
    } catch {
        // Surface to UI? For v1, fail silently and let the download
        // attempt with the stale URL — it might still work for ~minutes.
    }
}
```

Drop the `unsupportedKoboAlert` state and its `.alert` modifier.

#### A.4 — Verify KEPUB renders in Readium

Most likely works (KEPUB is valid EPUB 2.0 + Kobo span markup), but it hasn't been tested. The reader path is:

1. `env.openReader(book.id)` sets `activeReader`
2. `RootView` shows `.fullScreenCover(item: $env.activeReader)` → `ReaderView(bookID:)`
3. `ReaderView` constructs a Readium navigator from `book.fileURL`

If Readium's EPUB navigator rejects KEPUB for any reason, the fallback is to use a different content opener or pre-process the file. **Test this after A.1-A.3 land.** Don't pre-emptively add KEPUB-specific handling.

#### A.5 — Tests

Update `iOSReaderTests/Networking/OPDSCatalogAdapterTests.swift` and `iOSReaderTests/Services/BackendFactoryTests.swift` if any API shape changed. Add (or extend) a test for the LibraryRootView download routing — probably a TestableEnvironment pattern around env.downloads + env.library.

#### Acceptance criteria

- iOS app in Kobo mode → tap a catalog-only book → reader opens with a downloading state → book downloads → reader displays KEPUB content.
- iOS test suite still green.
- No "Kobo reading not yet supported" alert anywhere in the codebase.

### Task B: Manual smoke tests (Task 10.2 execution)

Run the 5 scenarios from `docs/superpowers/plans/2026-05-11-multi-protocol-sync.md` § "Smoke test checklist". Record pass/fail inline in that file. Specifically:

- **Smoke 1 (kosync end-to-end)**: install + sign in + library + download + read + verify kosync_progress row server-side.
- **Smoke 2 (Kobo end-to-end)**: requires Task A to be complete for the read part. Library populate is already verifiable today.
- **Smoke 3 (V1→V2 migration)**: N/A under the BC waiver (see checklist).
- **Smoke 4 (real Kobo ↔ iPhone)**: hardware-gated. Defer if no Kobo available.
- **Smoke 5 (protocol pinning)**: requires kosync + Kobo paired sequentially.

### Task C: CWA upstream PR

File the multi-device sync fix to `github.com/crocodilestick/Calibre-Web-Automated`. Include:

1. The two commits already on the fork (`ba3b06b` + `d203344`).
2. A new commit fixing the `else` branch (full-library mode timestamp filter). See `docs/cwa-fork-multidevice-sync.md` § "What's still broken in the fork".
3. PR description referencing `janeczku/calibre-web#2230` (closed without fix, same root cause).
4. Manual test plan: verify two-way-deletion still works (book removed from kobo_sync shelf → archived emitted on next device sync → row cleaned up from `kobo_synced_books`).

### Task D: Optional polish / follow-ups (low priority)

- **Empty-state UX**: Library tab's "Your library is empty" doesn't distinguish "no creds" from "creds present but server returned nothing". Could add a per-protocol hint.
- **Error reporting**: Settings' Test & Save catch shows `error.localizedDescription` which for Swift Error enums renders as `(Module.Type error N.)` — opaque. Use `String(describing: error)` or pattern-match on the specific BackendError cases for friendlier messages.
- **Pull-to-refresh on Home**: currently only the Library tab refreshes. Home doesn't but it queries the local store, so this matters only after a Library refresh has populated new books.
- **DownloadService session recreation**: if a user signs out of kosync and signs into Kobo, the existing background URLSession still has the kosync Authorization header in `httpAdditionalHeaders` (frozen at session-creation time). For v1, AppEnvironment.signOut clears state but the DownloadService instance persists across the protocol switch within a single app run. Worth verifying this doesn't break Kobo downloads in a kosync→Kobo flow.

## Cluster + simulator quick reference

```bash
# Cluster pod state
kubectl get pods -n calibre-web -l app=calibre-web
kubectl logs -n calibre-web deploy/calibre-web --tail=50

# CWA database checks
kubectl exec -n calibre-web deploy/calibre-web -- sqlite3 /config/app.db "SELECT COUNT(*) FROM kobo_synced_books;"
kubectl exec -n calibre-web deploy/calibre-web -- sqlite3 /config/app.db "SELECT id, user_id, book_id, kobo_reading_state_id IS NOT NULL AS has_state FROM kobo_synced_books LEFT JOIN kobo_reading_state USING(book_id) LIMIT 10;"

# Test the patched sync endpoint
curl -fsS "https://cwa.example.com/kobo/883ef62ff49543981f4fb79ca39780bc/v1/library/sync" \
  | python3 -c "import sys,json; data=json.load(sys.stdin); print({k: sum(1 for e in data if isinstance(e,dict) and k in e) for k in ['NewEntitlement','ChangedReadingState','DeletedTag','NewTag']})"

# Simulator: reset just the app data (preserves keychain)
xcrun simctl terminate FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22 me.iosreader.iOSReader
xcrun simctl uninstall FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22 me.iosreader.iOSReader
APP="$HOME/Library/Developer/Xcode/DerivedData/iOSReader-fainspluzqcdgkahlssrfmuegbnu/Build/Products/Debug-iphonesimulator/iOSReader.app"
xcrun simctl install FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22 "$APP"
xcrun simctl launch FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22 me.iosreader.iOSReader

# Simulator: fully reset (also wipes keychain — forces re-entering Kobo URL)
xcrun simctl erase FA029C0A-7A8F-4D6F-B7E5-55F5AB115A22

# Roll back the CWA patch (if needed)
# Edit manifests/calibre-web/deployment.yaml → image: crocodilestick/calibre-web-automated:v4.0.6
# git commit + push, wait ~2 min for ArgoCD + Recreate rollout
```

## Conventions to apply (from prior session)

- **No backwards compatibility** for the iOS schema work. Init params without inline defaults; update all call sites.
- **`.serialized` test suites** when touching `MockURLProtocol.handler` (Core tests).
- **`.distantPast` for missing timestamps**, never `Date()` — last-write-wins reconciliation must treat "age unknown" as "oldest possible".
- **Imperative commit subjects** `<type>(sync): <summary>`. `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer on assistant-driven commits.
- **Inline small review fixes** (<3 lines); dispatch subagents for multi-file / behavioral fixes.
- **No `--no-verify`, no amend, never force-push.**

## How to start next session

```text
Continue from docs/superpowers/plans/2026-05-12-post-phase-10-next-steps.md
Start with Task A. Verify the simulator + cluster state at the top of the doc
before dispatching anything.
```

The prior session's full task tracker (Tasks #1–#19) can be referenced for context but most items are complete. The unfinished ones map to Tasks A, B, C above.
