import Foundation
import SwiftData
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import Core

/// Engine state and orchestration for `ReaderView`. Owns everything that
/// describes "where the user is in the publication and what happens next" —
/// publication handle, current locator, scrub/jump state, prompt state,
/// TOC + positions cache.
///
/// The view keeps `@Query`, `@AppStorage`, and pure UI bookkeeping
/// (`uiVisible`, `fontHUD`, etc.). Methods on the VM take resolved
/// dependencies (`SyncService`, `ReadingStatsService`, `ModelContext`,
/// `Book`) as parameters rather than holding an `env` reference, so the
/// VM stays a pure state container.
@MainActor
@Observable
final class ReaderViewModel {

    // MARK: - Engine state

    var publication: Publication?
    var initialLocator: Locator?
    var loadError: String?
    var pendingPrompt: PromptInfo?

    /// Drops the navigator's first `locationDidChange` after mount. That
    /// emission is a load artifact ("I've finished initial layout at
    /// `initialLocator`") and carries no new user intent — buffering it
    /// races `resolveOpen` and could push the stale local position over a
    /// peer's newer write on the server.
    var initialEmissionSeen: Bool = false
    /// Set on the first real (post-initial-load) emission. Suppresses any
    /// late-arriving `.applyServer` / `.promptUser` resolution that would
    /// yank the user out of the position they're already reading at.
    var userHasNavigated: Bool = false

    var currentLocator: Locator?
    /// Set when the user accepts a cross-device progress prompt. Handed to
    /// `ReaderHost`; the container dedupes by `Locator.jsonString`, so we
    /// don't need to clear it after navigating.
    var pendingJump: Locator?
    /// Source tag for the next programmatic `pendingJump`.
    /// `consumeLocatorChange` consumes it on the next locator change; nil
    /// means the change came from a natural user swipe/tap.
    var pendingJumpSource: AdvanceSource?

    /// Whole-book progression (0–1) the user is dragging toward, or — after
    /// release — the position the bar should hold until the navigator confirms
    /// the jump. Drives both the bar's preview and the scrub HUD overlay.
    /// Cleared on cancel, or on the next locator update following commit.
    var scrubProgress: Double?
    /// True between `commitScrub` and the resulting `locationDidChange`. Keeps
    /// `scrubProgress` pinned at the release position so the bar doesn't flash
    /// back to the current locator before the async jump lands.
    var scrubCommitPending: Bool = false

    /// Flat list of every Readium position, cached after publication opens.
    /// Used to translate scrub progression → Locator without going through
    /// the publication service on every drag sample.
    var positions: [Locator] = []
    /// TOC entries flattened depth-first and tagged with their starting
    /// totalProgression. Sorted ascending; binary-searched to resolve the
    /// chapter heading for a scrub position.
    var tocProgressions: [(progression: Double, title: String, depth: Int)] = []
    /// Resource path (anchor stripped) → chapter title. Built alongside
    /// `tocProgressions` so the cross-device prompt can name the chapter
    /// a peer is on without re-walking the TOC.
    var tocTitlesByHref: [String: String] = [:]
    /// 1-based chapter index of the last locator emission we processed.
    /// Compared against the incoming locator's chapter to detect forward
    /// transitions for the haptic. Nil until the first emission lands or
    /// until the TOC has loaded.
    var lastSeenChapterIndex: Int?

    // MARK: - Types

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: CanonicalProgress
        let serverHref: String?
    }

    /// Outcome of consuming a locator-change emission. `nil` for the
    /// initial-load emission (the view should not buffer/announce). Non-nil
    /// outcomes carry everything the view needs to update sync/stats
    /// without re-deriving anything from VM state.
    struct LocatorChangeOutcome {
        let locatorJSON: String
        let totalProgression: Double
        let positionIndex: Int?
        let advanceSource: AdvanceSource
        let didCrossForwardChapter: Bool
    }

    // MARK: - Computed state

    /// 1-based Readium position index for the locator on screen.
    var currentPositionIndex: Int? {
        currentLocator.flatMap(positionIndex(for:))
    }

    /// 0-based index into `positions` for the current locator, or 0 if none.
    var currentPageIndex: Int {
        guard let locator = currentLocator,
              let idx = positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) }) else {
            return 0
        }
        return idx
    }

    /// 1-based index of the TOC entry whose progression is the largest still
    /// `<=` the current whole-book progression. nil when the TOC isn't loaded
    /// or the locator's progression precedes the first entry.
    var currentChapterIndex: Int? {
        currentLocator?.locations.totalProgression.flatMap(chapterIndex(at:))
    }

    /// Chapter title (from TOC) for the current progression, or "—" when
    /// the TOC hasn't loaded yet.
    var chapterTitleForCurrent: String {
        chapterTitle(at: currentLocator?.locations.totalProgression ?? 0)
    }

    /// "p. 142" — 1-based index of the current locator within the flat
    /// positions list. Falls back to "—" before positions are loaded.
    var pageLabel: String {
        guard !positions.isEmpty else { return "—" }
        return "p. \(currentPageIndex + 1)"
    }

    // MARK: - Loading

    /// Loads the persisted ReadingProgress (if any), opens the publication,
    /// and caches scrub metadata. Idempotent on `fileURL` — the view drives
    /// this through a `.task(id: book?.fileURL)`.
    func loadPublication(at fileURL: URL?, persistedLocatorJSON: String?) async {
        guard let fileURL else { return }
        if let json = persistedLocatorJSON {
            initialLocator = Self.parseLocator(json)
        }
        do {
            let pub = try await Self.openPublication(at: fileURL)
            publication = pub
            await loadScrubMetadata(for: pub)
        } catch {
            let diagnostics = Self.fileDiagnostics(at: fileURL)
            loadError = "Failed to open:\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n\(diagnostics)"
        }
    }

    /// Caches the positions list and TOC→progression map so scrubbing can
    /// resolve progress → Locator and progress → chapter heading without
    /// hitting the publication service on every drag sample. Failures here
    /// degrade gracefully: scrubbing still works (jumps via `positions`) and
    /// the chapter label falls back to an em-dash when TOC is unavailable.
    func loadScrubMetadata(for publication: Publication) async {
        positions = (try? await publication.positions().get()) ?? []
        let toc = (try? await publication.tableOfContents().get()) ?? []
        let built = Self.buildTOCProgressions(toc: toc, positions: positions)
        tocProgressions = built.progressions
        tocTitlesByHref = built.titlesByHref
    }

    // MARK: - Open resolution (cross-device sync)

    /// Runs in parallel with publication-loading. Network-bound, so the reader
    /// is already on screen by the time this returns. Late-arriving prompts /
    /// silent jumps are suppressed once `userHasNavigated` is true so they
    /// can't yank a user mid-read.
    func resolveOpen(book: Book, sync: SyncService?) async {
        guard let sync else { return }
        do {
            switch try await sync.onOpen(book: book) {
            case .useLocal:
                break
            case .applyServer(let progress):
                guard !userHasNavigated,
                      let locator = Self.parseLocator(progress.locatorJSON) else { return }
                pendingJumpSource = .resumeFromSync
                pendingJump = locator
            case .promptUser(let local, let server):
                guard !userHasNavigated else { return }
                pendingPrompt = PromptInfo(
                    local: local,
                    server: server,
                    serverHref: Self.parseHref(server.locatorJSON)
                )
            }
        } catch {
            // Best-effort; ignore failures.
        }
    }

    /// Accepts a cross-device prompt — promotes the server's locator to a
    /// `pendingJump` tagged as `.resumeFromSync`. View clears `pendingPrompt`
    /// after invoking.
    func acceptPrompt(_ info: PromptInfo) {
        guard let locator = Self.parseLocator(info.server.locatorJSON) else { return }
        pendingJumpSource = .resumeFromSync
        pendingJump = locator
    }

    // MARK: - Locator change handling

    /// Consume a `locationDidChange` emission from the navigator. Returns
    /// `nil` for the initial-load emission (don't buffer/announce). The view
    /// must update `currentLocator` itself (via `setCurrentLocator(_:)`)
    /// before calling — outcome reads VM state already.
    func consumeLocatorChange(_ locator: Locator) -> LocatorChangeOutcome? {
        let newChapterIdx = chapterIndex(at: locator.locations.totalProgression ?? 0)
        // Seed the baseline on the first (load-artifact) emission so the very
        // next user advance has something to compare against.
        if !initialEmissionSeen {
            initialEmissionSeen = true
            lastSeenChapterIndex = newChapterIdx
            return nil
        }
        userHasNavigated = true
        guard let json = try? locator.jsonString() else { return nil }
        let total = locator.locations.totalProgression ?? 0
        let source = pendingJumpSource ?? .swipe
        pendingJumpSource = nil
        // Haptic detector: only on linear (swipe/tap) forward chapter crossings.
        // Non-linear sources (TOC, scrub, AI jump, resume) just refresh the
        // baseline silently so the next linear advance compares correctly.
        let didCross = source.isLinear
            && (lastSeenChapterIndex.map { prev in (newChapterIdx ?? prev) > prev } ?? false)
        lastSeenChapterIndex = newChapterIdx
        let posIdx = positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) })
        return LocatorChangeOutcome(
            locatorJSON: json,
            totalProgression: total,
            positionIndex: posIdx,
            advanceSource: source,
            didCrossForwardChapter: didCross
        )
    }

    /// Called from `.onChange(of: currentLocator?.locations.totalProgression)`
    /// to release the post-commit scrub hold once the navigator catches up.
    func navigatorCaughtUpDuringScrub() {
        if scrubCommitPending {
            scrubCommitPending = false
            scrubProgress = nil
        }
    }

    // MARK: - Scrub

    func setScrubProgress(_ progress: Double) {
        // A fresh drag overrides any post-commit hold from a previous scrub —
        // the user is steering again.
        scrubCommitPending = false
        scrubProgress = progress
    }

    func cancelScrub() {
        scrubCommitPending = false
        scrubProgress = nil
    }

    /// Translates a whole-book progression into a Readium `Locator` via the
    /// cached positions list and hands it to the navigator through
    /// `pendingJump`. Keeps `scrubProgress` pinned at the release position so
    /// the bar holds steady until the navigator emits the new locator (cleared
    /// in `navigatorCaughtUpDuringScrub`). No-ops if positions aren't loaded.
    func commitScrub(to progression: Double) {
        guard !positions.isEmpty else {
            scrubProgress = nil
            return
        }
        let idx = max(0, min(positions.count - 1, Int(round(Double(positions.count - 1) * progression))))
        let target = positions[idx]

        // Release landed on the same position the navigator is already showing.
        // `applyPendingJump` would dedupe and never emit `locationDidChange`,
        // which would leave the bar pinned at the preview forever — clear now.
        if let currentProg = currentLocator?.locations.totalProgression,
           let targetProg = target.locations.totalProgression,
           abs(targetProg - currentProg) < 0.0001 {
            scrubProgress = nil
            return
        }

        scrubCommitPending = true
        pendingJumpSource = .scrubCommit
        pendingJump = target

        // Safety net for any other case where the jump produces no locator
        // emission (e.g. container dedupe against a stale `lastAppliedJumpJSON`).
        // The bar would otherwise stay stuck on the preview indefinitely.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            if self.scrubCommitPending {
                self.scrubCommitPending = false
                self.scrubProgress = nil
            }
        }
    }

    // MARK: - Jump-pill recovery

    /// Pill "Back to p. X" handler. Issues a programmatic return tagged so
    /// the service ignores it for stats. Returns `false` when the target is
    /// out of range (view should dismiss the pill without committing stay).
    func handleBackToPage(_ target: ReadingStatsService.JumpReturnTarget) -> Bool {
        guard target.fromPosition >= 0,
              target.fromPosition < positions.count else {
            return false
        }
        pendingJumpSource = .programmaticReturn
        pendingJump = positions[target.fromPosition]
        return true
    }

    // MARK: - Lookups

    /// Same 1-based Readium position lookup as `currentPositionIndex`, but
    /// applied to an arbitrary locator. Used to detect no-op TOC/bookmark
    /// taps that target the current page — those must not set
    /// `pendingJump`/`pendingJumpSource`, because the navigator won't emit a
    /// locator change for an in-place seek and the stale source tag would
    /// later be consumed by the next real advance.
    func positionIndex(for locator: Locator) -> Int? {
        if let pos = locator.locations.position { return pos }
        guard let prog = locator.locations.totalProgression,
              !positions.isEmpty else { return nil }
        let idx = positions.lastIndex { ($0.locations.totalProgression ?? 0) <= prog }
        return idx.map { $0 + 1 }
    }

    /// 1-based chapter index for an arbitrary whole-book progression. Shared
    /// between the chrome eyebrow and the haptic detector so both agree on
    /// what counts as "the current chapter."
    func chapterIndex(at progression: Double) -> Int? {
        var idx: Int?
        for (i, entry) in tocProgressions.enumerated() {
            if entry.progression <= progression {
                idx = i
            } else {
                break
            }
        }
        return idx.map { $0 + 1 }
    }

    /// Returns the title of the TOC entry that *starts at or before* the
    /// given whole-book progression. Falls back to an em-dash when the TOC
    /// wasn't loaded or the progression precedes the first mapped entry.
    func chapterTitle(at progression: Double) -> String {
        chapterContext(at: progression).current
    }

    /// Best-effort chapter title for a Kobo `Location.Source` or Readium
    /// `locator.href`. Tolerates the same prefix/suffix ambiguity as
    /// `buildTOCProgressions`, since locator hrefs may be relative to the
    /// EPUB root while TOC entries are relative to wherever the OPF lives.
    func chapterTitle(forHref href: String?) -> String? {
        guard let href else { return nil }
        let resource = href.components(separatedBy: "#").first ?? href
        if let exact = tocTitlesByHref[resource] { return exact }
        for (tocHref, title) in tocTitlesByHref where resource.hasSuffix(tocHref) || tocHref.hasSuffix(resource) {
            return title
        }
        return nil
    }

    /// Five-up chapter window for the scrub HUD:
    /// previous2 · previous1 · current · next1 · next2 at the given
    /// whole-book progression. `current` matches `chapterTitle(at:)`;
    /// outer slots are nil near book edges or when the TOC is empty.
    func chapterContext(
        at progression: Double
    ) -> (previous2: String?, previous1: String?, current: String, next1: String?, next2: String?) {
        guard !tocProgressions.isEmpty else { return (nil, nil, "—", nil, nil) }
        var idx = 0
        for (i, entry) in tocProgressions.enumerated() {
            if entry.progression <= progression {
                idx = i
            } else {
                break
            }
        }
        func at(_ offset: Int) -> String? {
            let target = idx + offset
            guard target >= 0, target < tocProgressions.count else { return nil }
            return tocProgressions[target].title
        }
        return (at(-2), at(-1), tocProgressions[idx].title, at(1), at(2))
    }

    // MARK: - Chapter list

    /// Builds the chapter list shown in the Contents tab. Pairs each TOC
    /// entry with its starting position (for the jump target + page number)
    /// and labels each chapter as read / current / unread. `book` is passed
    /// because `furthestLinearPosition` lives there.
    func chapterEntries(for book: Book?) -> [ReaderContentsView.Chapter] {
        guard !tocProgressions.isEmpty, !positions.isEmpty else { return [] }
        let watermark = maxReadProgression(for: book)
        let currentIdx0 = (currentChapterIndex ?? 0) - 1   // back to 0-based; -1 = none
        var out: [ReaderContentsView.Chapter] = []
        for (i, entry) in tocProgressions.enumerated() {
            guard let positionIdx = positions.firstIndex(where: {
                ($0.locations.totalProgression ?? 0) >= entry.progression
            }) else { continue }
            let nextProg: Double = (i + 1 < tocProgressions.count)
                ? tocProgressions[i + 1].progression
                : 1.0
            let status: ReaderContentsView.Status
            if i == currentIdx0 {
                status = .current
            } else if nextProg <= watermark {
                status = .read
            } else {
                status = .unread
            }
            out.append(.init(
                index: i + 1,
                roman: Self.romanNumeral(i + 1),
                title: entry.title,
                depth: entry.depth,
                page: positionIdx + 1,
                status: status,
                locator: positions[positionIdx]
            ))
        }
        return out
    }

    /// Highest progression reached for this book — drives the "read" check
    /// next to chapters the user has already passed. Backed by the per-book
    /// linear-read watermark.
    func maxReadProgression(for book: Book?) -> Double {
        guard let book, positions.count > 1 else { return 0 }
        return Double(book.furthestLinearPosition) / Double(positions.count - 1)
    }

    // MARK: - Prompt title

    func promptTitle(for info: PromptInfo) -> String {
        if let title = chapterTitle(forHref: info.serverHref) {
            return "Another device is in '\(title)' — switch?"
        }
        return "Continue from another device?"
    }

    // MARK: - Statics

    /// Roman numeral 1...3999. Past that, returns the arabic numeral.
    static func romanNumeral(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let pairs: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var n = n
        var out = ""
        for (v, sym) in pairs {
            while n >= v {
                out += sym
                n -= v
            }
        }
        return out
    }

    static func parseHref(_ json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["href"] as? String
    }

    /// Decodes a Readium locator JSON string via the modern `JSONValue` →
    /// `Locator(json:)` path.
    static func parseLocator(_ json: String?) -> Locator? {
        guard let json,
              let jsonValue = try? JSONValue(jsonString: json),
              let locator = try? Locator(json: jsonValue, warnings: nil)
        else { return nil }
        return locator
    }

    static func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw ReaderOpenError.invalidFileURL(url)
        }

        let asset = try await assetRetriever.retrieve(url: fileURL)
            .mapError { ReaderOpenError.asset($0) }
            .get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        return try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { ReaderOpenError.publication($0) }
            .get()
    }

    static func fileDiagnostics(at url: URL) -> String {
        var lines: [String] = []
        lines.append("URL: \(url.absoluteString)")
        lines.append("Scheme: \(url.scheme ?? "<none>")")
        lines.append("Path: \(url.path)")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        lines.append("Exists: \(exists)")
        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                lines.append("Size: \(size) bytes")
            }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let head = handle.readData(ofLength: 4)
                lines.append("Head: \(head.map { String(format: "%02x", $0) }.joined())")
            } else {
                lines.append("Head: <unreadable>")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Walks the TOC depth-first, mapping each entry to its starting
    /// totalProgression by matching against the first reading-order position
    /// that lives in the same resource. Entries whose href doesn't appear in
    /// the reading order are dropped. Result is sorted ascending so a
    /// linear scan (or future binary search) can find "current chapter" for
    /// a given progression.
    static func buildTOCProgressions(
        toc: [ReadiumShared.Link],
        positions: [Locator]
    ) -> (progressions: [(progression: Double, title: String, depth: Int)], titlesByHref: [String: String]) {
        var flat: [(href: String, title: String, depth: Int)] = []
        func walk(_ links: [ReadiumShared.Link], depth: Int) {
            for link in links {
                let title = link.title ?? ""
                if !title.isEmpty {
                    flat.append((href: link.href, title: title, depth: depth))
                }
                walk(link.children, depth: depth + 1)
            }
        }
        walk(toc, depth: 0)

        var mapped: [(progression: Double, title: String, depth: Int)] = []
        var titlesByHref: [String: String] = [:]
        for entry in flat {
            // TOC hrefs often include #anchor; positions key on the resource
            // path. Compare resource-only — anchor granularity is not enough
            // to distinguish TOC entries in the typical EPUB.
            let entryResource = entry.href.components(separatedBy: "#").first ?? entry.href
            if titlesByHref[entryResource] == nil {
                titlesByHref[entryResource] = entry.title
            }
            guard let pos = positions.first(where: { $0.href.string.hasSuffix(entryResource) || entryResource.hasSuffix($0.href.string) }),
                  let progression = pos.locations.totalProgression else { continue }
            mapped.append((progression: progression, title: entry.title, depth: entry.depth))
        }
        return (mapped.sorted { $0.progression < $1.progression }, titlesByHref)
    }
}

enum ReaderOpenError: LocalizedError {
    case invalidFileURL(URL)
    case asset(AssetRetrieveURLError)
    case publication(PublicationOpenError)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL(let url):
            return "Readium rejected the file URL: \(url.absoluteString)"
        case .asset(let inner):
            return "Asset retrieval failed: \(Self.describe(inner))"
        case .publication(let inner):
            return "Publication open failed: \(inner.localizedDescription)"
        }
    }

    private static func describe(_ error: AssetRetrieveURLError) -> String {
        switch error {
        case .schemeNotSupported(let scheme):
            return "scheme '\(scheme.rawValue)' not supported"
        case .formatNotSupported:
            return "format not recognized (sniffer found no specifications — wrong extension / corrupted file / missing file)"
        case .reading(let inner):
            return "read error: \(inner.localizedDescription)"
        }
    }
}
