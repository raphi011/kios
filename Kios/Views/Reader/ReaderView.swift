import SwiftUI
import SwiftData
import UIKit
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumNavigator
import Core

/// Immersive reader. Presented as a `fullScreenCover` from `RootView`.
struct ReaderView: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @Query private var books: [Book]
    @Query private var downloads: [Download]
    /// Sessions for this book — drives the "time left" estimate in the chrome.
    @Query private var sessionsForBook: [ReadingSession]
    @Query private var bookmarksForBook: [Bookmark]

    @AppStorage("reader.fontSizePct") private var fontSizePct: Int = 100
    /// On by default. Plays a subtle haptic when a normal swipe/tap crosses
    /// into a new chapter. Silent for TOC jumps, scrubs, AI quote jumps, and
    /// sync-resume — the toggle gates only linear chapter transitions.
    @AppStorage("reader.hapticChapterEnabled") private var hapticChapterEnabled: Bool = true

    @State private var publication: Publication?
    @State private var initialLocator: Locator?
    @State private var loadError: String?
    @State private var pendingPrompt: PromptInfo?

    /// Drops the navigator's first `locationDidChange` after mount. That
    /// emission is a load artifact ("I've finished initial layout at
    /// `initialLocator`") and carries no new user intent — buffering it
    /// races `resolveOpen` and could push the stale local position over a
    /// peer's newer write on the server.
    @State private var initialEmissionSeen: Bool = false
    /// Set on the first real (post-initial-load) emission. Suppresses any
    /// late-arriving `.applyServer` / `.promptUser` resolution that would
    /// yank the user out of the position they're already reading at.
    @State private var userHasNavigated: Bool = false

    @State private var uiVisible: Bool = false
    /// Set true by the `⊟` button in the reader top bar to present the
    /// Contents / Bookmarks / Notes modal. Setting back to false dismisses.
    @State private var showContents: Bool = false
    /// Non-nil while the Insights sheet is presented. Holds the snapshot of
    /// chapter context taken at tap time, plus the per-session
    /// `BookAnalysisService`, so the sheet sees a stable context even if the
    /// reader navigates while it's open.
    @State private var insightsSheet: InsightsSheetContext?
    /// Non-nil while the Ask-AI sheet is presented. Snapshot of selection +
    /// chapter context captured when the user picks "Ask AI" from the
    /// text-selection edit menu.
    @State private var askSheet: AskSheetContext?
    /// Lazily created on the first "Ask AI" request — needs the per-reader
    /// `Publication` to construct the text extractor. Cleared on reader close.
    @State private var summaryService: AISummaryService?
    @State private var fontHUD: Int? = nil
    /// Percent shown in the brightness HUD (0...100). Driven by the
    /// `onBrightnessUpdate` callback from `ReaderInputHandlers`' UIKit pan
    /// recognizer. `nil` hides the HUD.
    @State private var brightnessHUD: Int? = nil
    @State private var currentLocator: Locator?
    /// Set when the user accepts a cross-device progress prompt. Handed to
    /// `ReaderHost`; the container dedupes by `Locator.jsonString`, so we
    /// don't need to clear it after navigating.
    @State private var pendingJump: Locator?
    /// Source tag for the next programmatic `pendingJump`. `pushLocator`
    /// consumes it on the next locator change; nil means the change came
    /// from a natural user swipe/tap.
    @State private var pendingJumpSource: AdvanceSource?
    /// Whole-book progression (0–1) the user is dragging toward, or — after
    /// release — the position the bar should hold until the navigator confirms
    /// the jump. Drives both the bar's preview and the scrub HUD overlay.
    /// Cleared on cancel, or on the next locator update following commit.
    @State private var scrubProgress: Double?
    /// True between `commitScrub` and the resulting `locationDidChange`. Keeps
    /// `scrubProgress` pinned at the release position so the bar doesn't flash
    /// back to the current locator before the async jump lands.
    @State private var scrubCommitPending: Bool = false
    /// Flat list of every Readium position, cached after publication opens.
    /// Used to translate scrub progression → Locator without going through
    /// the publication service on every drag sample.
    @State private var positions: [Locator] = []
    /// TOC entries flattened depth-first and tagged with their starting
    /// totalProgression. Sorted ascending; binary-searched to resolve the
    /// chapter heading for a scrub position.
    @State private var tocProgressions: [(progression: Double, title: String, depth: Int)] = []
    /// Resource path (anchor stripped) → chapter title. Built alongside
    /// `tocProgressions` so the cross-device prompt can name the chapter
    /// a peer is on without re-walking the TOC.
    @State private var tocTitlesByHref: [String: String] = [:]
    /// 1-based chapter index of the last locator emission we processed.
    /// Compared against the incoming locator's chapter to detect forward
    /// transitions for the haptic. Nil until the first emission lands or
    /// until the TOC has loaded.
    @State private var lastSeenChapterIndex: Int?
    /// Synchronous bridge to the underlying container's selection state.
    /// Consulted by `swipeDownDismissGesture` so a multi-line text-selection
    /// drag doesn't trigger a dismiss. Stable for the lifetime of this view.
    @State private var selectionProbe = ReaderSelectionProbe()

    init(bookID: UUID) {
        self.bookID = bookID
        let id = bookID
        _books = Query(filter: #Predicate<Book> { $0.id == id })
        _downloads = Query(filter: #Predicate<Download> { $0.bookID == id })
        _sessionsForBook = Query(filter: #Predicate<ReadingSession> { $0.bookID == id })
        _bookmarksForBook = Query(filter: #Predicate<Bookmark> { $0.bookID == id })
    }

    private var book: Book? { books.first }
    private var download: Download? { downloads.first }

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: CanonicalProgress
        let serverHref: String?
    }

    /// Snapshot of context captured when the user opens the Insights sheet.
    /// `Identifiable` so `.sheet(item:)` can present it. The
    /// `BookAnalysisService` is bundled into the context (rather than read
    /// from sibling state) so SwiftUI's sheet-content closure sees a stable
    /// instance — sibling `@State` can present a stale snapshot.
    struct InsightsSheetContext: Identifiable {
        let id = UUID()
        let bookID: UUID
        let chapterHref: String?
        let service: BookAnalysisService
    }

    /// Snapshot of selection + chapter context captured when the user picks
    /// "Ask AI" from the navigator's text-selection edit menu. Identifiable
    /// so `.sheet(item:)` can present `AskAboutSelectionSheet` against it.
    /// Bundles the service for the same reason as `InsightsSheetContext`.
    struct AskSheetContext: Identifiable {
        let id = UUID()
        let selection: String
        let bookID: UUID
        let bookTitle: String
        let chapterTitle: String?
        let engine: AIEngine
        let service: AISummaryService
    }

    /// Populated when the user taps an AI affordance but neither engine is
    /// currently usable. Drives the `.alert(item:)` below — the user sees
    /// *why* the action didn't proceed instead of a silent no-op.
    struct AIUnavailableAlert: Identifiable {
        let id = UUID()
        let message: String
    }
    @State private var aiUnavailableAlert: AIUnavailableAlert?

    var body: some View {
        ZStack {
            // EPUB content stretches edge-to-edge horizontally and behind the
            // Dynamic Island. Bottom safe area (home indicator) is respected
            // so body text doesn't run under it. Chrome is a floating overlay,
            // never a safeAreaInset — toggling an inset would resize the
            // navigator and reflow the EPUB columns.
            content
                .ignoresSafeArea(edges: [.top, .horizontal])
            chromeOverlay
            pillOverlay
            hudOverlay
        }
        // Pin to white instead of `Color(.systemBackground)`: in dark mode the
        // system background is black, but Readium renders the EPUB on a white
        // page. The mismatch shows up as a black bar in the home-indicator
        // safe area where the navigator stops painting. Revisit when we ship
        // a dark EPUB theme — at that point this needs to track the active
        // Readium theme's body background.
        .background(Color.white.ignoresSafeArea())
        .simultaneousGesture(swipeDownDismissGesture())
        .task(id: book?.fileURL) {
            async let p: Void = loadPublicationIfReady()
            async let r: Void = resolveOpen()
            _ = await (p, r)
            // Stats: open a session once the publication is loaded.
            // Position = current locator's index in the positions list,
            // or 0 if no current locator yet.
            let initialPosition: Int
            if let locator = currentLocator,
               let idx = positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) }) {
                initialPosition = idx
            } else if let initial = initialLocator,
                      let idx = positions.firstIndex(where: { $0.href.isEquivalentTo(initial.href) }) {
                initialPosition = idx
            } else {
                initialPosition = 0
            }
            if !positions.isEmpty {
                if let book, book.totalPositions != positions.count {
                    book.totalPositions = positions.count
                    try? context.save()
                }
                env.stats.sessionDidOpen(
                    bookID: bookID,
                    initialPosition: initialPosition,
                    totalPositions: positions.count
                )
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await flush() }
            }
        }
        .onChange(of: currentLocator?.locations.totalProgression) { _, _ in
            // Navigator caught up — drop the post-commit hold so the bar tracks
            // the real locator again.
            if scrubCommitPending {
                scrubCommitPending = false
                scrubProgress = nil
            }
        }
        .onDisappear {
            Task { await flush() }
            env.stats.sessionDidClose(reason: .closed)
            env.activeReader = nil
        }
        .fullScreenCover(isPresented: $showContents) {
            // Chapter and bookmark taps both dispatch via `.tocJump` so the
            // recovery pill surfaces and the user can land back where they
            // were. One closure shared between the two so the source tag
            // can't drift.
            let jump: (Locator) -> Void = { locator in
                pendingJumpSource = .tocJump
                pendingJump = locator
                showContents = false
            }
            ReaderContentsView(
                bookTitle: book?.title ?? "",
                chapters: chapterEntries,
                bookmarks: bookmarkEntries,
                onJump: jump,
                onJumpToBookmark: jump,
                onDeleteBookmark: { id in deleteBookmark(id: id) },
                onDismiss: { showContents = false }
            )
        }
        .sheet(item: $insightsSheet) { context in
            if let book = book {
                InsightsSheet(
                    bookID: context.bookID,
                    book: book,
                    currentChapterHref: context.chapterHref,
                    makeService: { context.service },
                    onJumpRequest: { href, quote in
                        insightsSheet = nil
                        pendingJumpSource = .aiQuoteJump
                        jumpAndSearch(href: href, quote: quote)
                    },
                    onDismiss: { insightsSheet = nil }
                )
            }
        }
        .sheet(item: $askSheet) { context in
            AskAboutSelectionSheet(
                selection: context.selection,
                bookID: context.bookID,
                bookTitle: context.bookTitle,
                chapterTitle: context.chapterTitle,
                engine: context.engine,
                onClose: { askSheet = nil },
                service: context.service
            )
        }
        .alert(item: $aiUnavailableAlert) { ctx in
            Alert(
                title: Text("AI engine unavailable"),
                message: Text(ctx.message),
                dismissButton: .default(Text("OK"))
            )
        }
        // NB: do NOT clear `summaryService` in `.onDisappear` — SwiftUI fires
        // onDisappear on this view when the AI sheet (`.sheet(item:)`) covers
        // it, which clears the service before the sheet body reads it and
        // renders the sheet blank. ReaderView is recreated on each
        // fullScreenCover presentation, so per-book `@State` is naturally
        // fresh without this cleanup.
    }

    // MARK: - Contents/Bookmarks/Notes data

    /// Builds the chapter list shown in the Contents tab. Pairs each TOC
    /// entry with its starting position (for the jump target + page number)
    /// and labels each chapter as read / current / unread.
    private var chapterEntries: [ReaderContentsView.Chapter] {
        guard !tocProgressions.isEmpty, !positions.isEmpty else { return [] }
        let watermark = maxReadProgression
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
                roman: romanNumeral(i + 1),
                title: entry.title,
                depth: entry.depth,
                page: positionIdx + 1,
                status: status,
                locator: positions[positionIdx]
            ))
        }
        return out
    }

    /// Maps the persisted Bookmark rows into the view-facing struct.
    /// Bookmarks whose stored locator JSON can no longer be parsed are
    /// dropped — defensive, shouldn't happen in practice. Sorted by
    /// position ascending so the list reads top-to-bottom in book order.
    private var bookmarkEntries: [ReaderContentsView.Bookmark] {
        bookmarksForBook
            .sorted { $0.position < $1.position }
            .compactMap { b in
                guard let loc = parseLocator(b.locatorJSON) else { return nil }
                return ReaderContentsView.Bookmark(
                    id: b.id,
                    page: b.position,
                    chapterTitle: b.chapterTitle,
                    locator: loc
                )
            }
    }

    /// Removes the bookmark row with the given id from this book's set.
    /// No-op when not found (e.g. the row was deleted on another device
    /// once sync lands, or the modal raced a toggle in the chrome).
    private func deleteBookmark(id: UUID) {
        guard let target = bookmarksForBook.first(where: { $0.id == id }) else { return }
        context.delete(target)
        try? context.save()
    }

    /// Highest progression reached for this book — drives the "read" check
    /// next to chapters the user has already passed. Backed by the
    /// per-book linear-read watermark, which Task 5's source-tagged
    /// advances will start writing. Returns 0 until then (same observable
    /// behaviour as a fresh install).
    private var maxReadProgression: Double {
        guard let book, positions.count > 1 else { return 0 }
        return Double(book.furthestLinearPosition) / Double(positions.count - 1)
    }

    /// 1-based Readium position index for the locator on screen. Prefer
    /// the locator's own `position` (set by the publication's positions
    /// service); fall back to the largest position whose totalProgression
    /// is ≤ the current one — same lookup style as `chapterEntries`.
    private var currentPositionIndex: Int? {
        if let pos = currentLocator?.locations.position { return pos }
        guard let prog = currentLocator?.locations.totalProgression,
              !positions.isEmpty else { return nil }
        let idx = positions.lastIndex { ($0.locations.totalProgression ?? 0) <= prog }
        return idx.map { $0 + 1 }
    }

    /// True when a bookmark exists for the current page. `bookmarksForBook`
    /// is already filtered by `bookID` in the `@Query` predicate, so no
    /// second book-scope check here.
    private var isCurrentPageBookmarked: Bool {
        guard let position = currentPositionIndex else { return false }
        return bookmarksForBook.contains { $0.position == position }
    }

    @ViewBuilder
    private var content: some View {
        if let book {
            if book.fileURL != nil, let publication {
                let id = book.id
                // Snapshot href→index outside the @Sendable closure so we
                // don't capture the non-Sendable `Publication`. The reading
                // order is static for the duration of the reader session.
                let chapterIndexByHref: [String: Int] = Dictionary(
                    uniqueKeysWithValues: publication.readingOrder.enumerated().map { ($1.href, $0) }
                )
                ReaderHost(
                    publication: publication,
                    initialLocator: initialLocator,
                    pendingJump: pendingJump,
                    fontSizePct: fontSizePct,
                    canAskAI: env.aiSettings.featuresEnabled,
                    onLocatorChange: { @Sendable locator in
                        Task { @MainActor in
                            currentLocator = locator
                            await pushLocator(bookID: id, locator: locator)
                            // Track furthest chapter the user has reached.
                            // Drives "analyze up to here" gating on the
                            // Characters tab so spoilers are clipped to the
                            // user's read horizon. Re-fetch the book row
                            // from the @Query result instead of capturing
                            // the non-Sendable `Book` instance.
                            let idx = chapterIndexByHref[locator.href.string] ?? 0
                            if let book = books.first, idx > book.maxChapterIndexReached {
                                book.maxChapterIndexReached = idx
                                try? context.save()
                            }
                        }
                    },
                    onCenterTap: { withAnimation(.easeOut(duration: 0.2)) { uiVisible.toggle() } },
                    onPageTurn: {
                        guard uiVisible else { return }
                        withAnimation(.easeOut(duration: 0.2)) { uiVisible = false }
                    },
                    onPinchUpdate: { pct in
                        // Spec: fade-in 0.15s, fade-out 0.3s.
                        let duration = (pct == nil) ? 0.3 : 0.15
                        withAnimation(.easeOut(duration: duration)) { fontHUD = pct }
                    },
                    onPinchCommit: { pct in
                        fontSizePct = pct
                    },
                    onBrightnessUpdate: { pct in
                        let duration = (pct == nil) ? 0.3 : 0.08
                        withAnimation(.easeOut(duration: duration)) {
                            brightnessHUD = pct
                        }
                    },
                    onDismissRequested: { dismiss() },
                    onAskAIRequested: { selection in presentAskSheet(selection: selection) },
                    selectionProbe: selectionProbe
                )
                .alert(item: $pendingPrompt) { info in
                    Alert(
                        title: Text(promptTitle(for: info)),
                        message: Text(relativeReadMessage(for: info.server)),
                        primaryButton: .default(Text("Continue")) {
                            if let locator = parseLocator(info.server.locatorJSON) {
                                pendingJumpSource = .resumeFromSync
                                pendingJump = locator
                            }
                        },
                        secondaryButton: .cancel(Text("Stay here"))
                    )
                }
            } else if book.fileURL == nil {
                DownloadingView(book: book, download: download)
            } else if let loadError {
                Text(loadError).foregroundStyle(.orange).padding()
            } else {
                ProgressView("Opening…").tint(.white)
            }
        } else {
            Text("Book not found").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        if uiVisible {
            VStack(spacing: 0) {
                EditorialReaderTopBar(
                    title: book?.title ?? "",
                    onLibrary: { dismiss() },
                    onContents: { showContents = true },
                    isBookmarked: isCurrentPageBookmarked,
                    onToggleBookmark: { toggleBookmark() }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                EditorialReaderBottomBar(
                    chapterEyebrow: chapterEyebrow,
                    chapterTitle: chapterTitleForCurrent,
                    pageLabel: pageLabel,
                    timeLeftLabel: timeLeftLabel,
                    locator: currentLocator,
                    scrubProgress: scrubProgress,
                    tocProgressions: tocProgressions.map(\.progression),
                    resolveChapterTitle: chapterTitle(at:),
                    onScrubUpdate: { progress in
                        // A fresh drag overrides any post-commit hold from a
                        // previous scrub — the user is steering again.
                        scrubCommitPending = false
                        scrubProgress = progress
                    },
                    onScrubCommit: { progress in commitScrub(to: progress) },
                    onScrubCancel: {
                        scrubCommitPending = false
                        scrubProgress = nil
                    },
                    onInsights: { presentInsightsSheet() },
                    canShowInsights: env.aiSettings.featuresEnabled,
                    engineLabel: {
                        // When no engine resolves, label with the user's
                        // *preferred* engine so the eyebrow doesn't read
                        // empty. Tapping surfaces the explainer alert.
                        switch resolvedAIEngine ?? env.aiSettings.preferredEngine {
                        case .foundationModels: return "Built-in (Apple Intelligence)"
                        case .gemma4_e4b: return "Gemma 4 E4B (on-device)"
                        }
                    }()
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Chrome string helpers

    /// 1-based index of the TOC entry whose progression is the largest still
    /// `<=` the current whole-book progression. nil when the TOC isn't loaded
    /// or the locator's progression precedes the first entry.
    private var currentChapterIndex: Int? {
        currentLocator?.locations.totalProgression.flatMap(chapterIndex(at:))
    }

    /// 1-based chapter index for an arbitrary whole-book progression. Shared
    /// between the chrome eyebrow and the haptic detector so both agree on
    /// what counts as "the current chapter."
    private func chapterIndex(at progression: Double) -> Int? {
        var idx: Int?
        for (i, entry) in tocProgressions.enumerated() {
            if entry.progression <= progression {
                idx = i
            } else {
                break
            }
        }
        return idx.map { $0 + 1 }   // 1-based
    }

    /// "CHAPTER IV" — Roman numeral, falling back to an arabic numeral past
    /// the supported range or to a generic eyebrow when no chapter is known.
    private var chapterEyebrow: String {
        guard let i = currentChapterIndex else { return "READING" }
        return "CHAPTER \(romanNumeral(i))"
    }

    /// Chapter title (from TOC) for the current progression, or "—" when
    /// the TOC hasn't loaded yet.
    private var chapterTitleForCurrent: String {
        chapterTitle(at: currentLocator?.locations.totalProgression ?? 0)
    }

    /// "p. 142 / 316" — index of the current locator within the flat positions
    /// list, plus the total. Falls back to "—" before positions are loaded.
    private var pageLabel: String {
        guard !positions.isEmpty else { return "—" }
        let idx = currentPageIndex
        return "p. \(idx + 1) / \(positions.count)"
    }

    private var currentPageIndex: Int {
        guard let locator = currentLocator,
              let idx = positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) }) else {
            return 0
        }
        return idx
    }

    /// "3h 12m left" — extrapolated from time-so-far × (1 − progress) / progress.
    /// Hidden (nil) until at least one session has landed and the locator is
    /// past 0.1% (the early-extrapolation singularity).
    private var timeLeftLabel: String? {
        let total = sessionsForBook.reduce(0) { $0 + $1.durationSeconds }
        let progress = currentLocator?.locations.totalProgression ?? 0
        guard total > 0, progress > 0.001, progress < 1.0 else { return nil }
        let remaining = Int(Double(total) * (1.0 - progress) / progress)
        return StatsFormatters.time(seconds: remaining) + " left"
    }

    /// Roman numeral 1...3999. Past that, returns the arabic numeral — Romans
    /// run out of letters and books with that many chapters are not a thing.
    private func romanNumeral(_ n: Int) -> String {
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

    /// Persistent pill overlay — visible regardless of `uiVisible` so the
    /// user can always return after a nav jump. Floats below the top safe
    /// area, dodging the chrome's top bar when chrome is showing.
    @ViewBuilder
    private var pillOverlay: some View {
        if let target = env.stats.pendingJumpReturn {
            VStack {
                JumpRecoveryPill(
                    target: target,
                    onBack: { handleBackToPage(target) },
                    onStay: { env.stats.dismissJumpPill(commitStay: true) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, 16)
                .padding(.top, uiVisible ? 72 : 16)
                // 72 = top bar's 8pt inset + 52pt height + 12pt breathing.
                // Sized once for the current chrome layout; revisit if chrome changes.
                Spacer()
            }
            .animation(.snappy, value: env.stats.pendingJumpReturn)
        }
    }

    @ViewBuilder
    private var hudOverlay: some View {
        if let pct = fontHUD {
            ReaderFontHUD(pct: pct)
                .transition(.opacity)
        } else if let pct = brightnessHUD {
            ReaderBrightnessHUD(pct: pct)
                .transition(.opacity)
        } else if let progress = scrubProgress {
            ReaderScrubHUD(progress: progress, chapter: chapterTitle(at: progress))
                .transition(.opacity)
        }
    }


    // MARK: - AI summary

    /// The engine `AIAvailability` resolved against the user's preference, or
    /// `nil` when AI is disabled / no engine is usable. Recomputed on every
    /// access — `installationStatus(for:)` is a stat call, cheap enough for a
    /// chrome-render cadence.
    private var resolvedAIEngine: AIEngine? {
        let availability = AIAvailability.resolve(
            userEnabled: env.aiSettings.featuresEnabled,
            preferredEngine: env.aiSettings.preferredEngine,
            capability: .current,
            assetStore: env.aiAssetStore,
            downloads: env.aiDownloadService
        )
        return availability.resolved(
            preferred: env.aiSettings.preferredEngine,
            userEnabled: env.aiSettings.featuresEnabled
        )
    }

    /// Builds a human-readable explanation for `aiUnavailableAlert` from the
    /// current per-engine availability. Reads the user's preferred engine
    /// first (because that's what they expect to work) and falls back to
    /// describing the other engine's state so the message points to whatever
    /// fix is closest at hand.
    private func aiUnavailableMessage() -> String {
        let availability = AIAvailability.resolve(
            userEnabled: env.aiSettings.featuresEnabled,
            preferredEngine: env.aiSettings.preferredEngine,
            capability: .current,
            assetStore: env.aiAssetStore,
            downloads: env.aiDownloadService
        )
        let preferred = env.aiSettings.preferredEngine
        return Self.explanation(
            for: preferred == .foundationModels ? availability.fm : availability.gemma,
            engine: preferred
        )
    }

    private static func explanation(for state: EngineAvailability, engine: AIEngine) -> String {
        let prefix: String = {
            switch engine {
            case .foundationModels: return "Built-in (Apple Intelligence)"
            case .gemma4_e4b:       return "Bigger context (Gemma 4 E4B)"
            }
        }()
        switch state {
        case .available:
            return "\(prefix) is available, but the request couldn't complete. Try again."
        case .userDisabled:
            return "Enable AI in Settings → AI to use \(prefix)."
        case .unsupportedOS:
            return "\(prefix) requires iOS 26 or later. Update your device or switch engine in Settings → AI."
        case .unsupportedDevice:
            switch engine {
            case .foundationModels:
                return "Apple Intelligence isn't supported on this device. Switch to Bigger context in Settings → AI."
            case .gemma4_e4b:
                return "Bigger context requires roughly 8 GB of RAM. Switch to Built-in in Settings → AI."
            }
        case .modelNotReady:
            return "Apple Intelligence isn't ready yet. Open the iOS Settings app → Apple Intelligence & Siri, make sure it's on, and let it finish downloading."
        case .modelNotDownloaded:
            return "The Bigger context model isn't downloaded yet. Open Settings → AI to install it (~5.2 GB)."
        case .modelDownloading(let p):
            return "The Bigger context model is still downloading (\(Int(p * 100))%). Try again once it's installed."
        case .modelCorrupt:
            return "The Bigger context model files don't match the catalog. Open Settings → AI, delete the model, and re-download."
        }
    }

    /// Captures the current chapter context and presents the Insights sheet.
    /// The sheet itself drives Analyze on demand; this entry only opens it.
    /// Shows `aiUnavailableAlert` when AI is disabled / no engine resolves,
    /// so the user understands why nothing happened. No-ops when the
    /// publication isn't loaded yet.
    private func presentInsightsSheet() {
        guard let publication else { return }
        guard resolvedAIEngine != nil else {
            aiUnavailableAlert = AIUnavailableAlert(message: aiUnavailableMessage())
            return
        }
        let service = env.makeBookAnalysisService(publication: publication)
        let href = (currentLocator ?? initialLocator)?.href.string
        insightsSheet = InsightsSheetContext(
            bookID: bookID,
            chapterHref: href,
            service: service
        )
    }

    /// Called when the user taps a character mention in the Insights sheet.
    /// Navigates to the chapter, then best-effort searches for the verbatim
    /// quote and jumps to the first match. A miss (or a publication without
    /// a search service) lands the user at the chapter's start.
    private func jumpAndSearch(href: String, quote: String) {
        guard let publication else { return }
        // Land at the chapter's start first by picking the earliest cached
        // `Locator` whose href matches the reading-order entry. Falls back to
        // any positional match if href comparison is anchor-dirty.
        guard let chapterStart = positions.first(where: { $0.href.string == href })
            ?? positions.first(where: { $0.href.string.hasSuffix(href) || href.hasSuffix($0.href.string) })
        else { return }
        pendingJump = chapterStart
        Task { @MainActor in
            // Yield a frame so the navigator can begin the chapter jump
            // before we drive `pendingJump` to the search hit. Tight without
            // sleeping; the deduper inside `ReaderHost` ignores the second
            // jump if `applyPendingJump` hasn't unrolled the first yet, so
            // this can no-op in the wrong order — silent miss is acceptable.
            try? await Task.sleep(for: .milliseconds(400))
            let result = await publication.search(query: quote)
            guard case .success(let iterator) = result else { return }
            let pageResult = await iterator.next()
            if case .success(let collection) = pageResult,
               let locator = collection?.locators.first {
                pendingJumpSource = .aiQuoteJump
                pendingJump = locator
            }
        }
    }

    /// Snapshot the current chapter context for the supplied selection text
    /// and present `AskAboutSelectionSheet`. Reuses the same lazily-built
    /// `AISummaryService` as the chapter summary path — both rely on it
    /// streaming through the resolved engine's `LanguageModel`. Shows the
    /// `aiUnavailableAlert` when AI is enabled but no engine resolves, so
    /// the user understands why the action didn't proceed.
    private func presentAskSheet(selection: String) {
        guard let publication, !selection.isEmpty else { return }
        guard let engine = resolvedAIEngine else {
            aiUnavailableAlert = AIUnavailableAlert(message: aiUnavailableMessage())
            return
        }
        let service = summaryService ?? AISummaryService(
            modelContext: context,
            modelProvider: env.aiModelProvider,
            textExtractor: PublicationChapterTextExtractor(publication: publication)
        )
        summaryService = service
        let href = currentLocator?.href.string ?? initialLocator?.href.string
        let title: String? = href.flatMap(chapterTitle(forHref:)) ?? chapterTitleForCurrent
        askSheet = AskSheetContext(
            selection: selection,
            bookID: bookID,
            bookTitle: book?.title ?? "",
            chapterTitle: title,
            engine: engine,
            service: service
        )
    }

    private func swipeDownDismissGesture() -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                // Skip dismiss whenever the user has text selected — a
                // multi-line selection drag (long-press + extend handles
                // downward) matches the same translation/velocity shape as a
                // dismiss drag and would otherwise close the reader on the
                // user mid-selection.
                if selectionProbe.hasSelection() { return }
                // Drags that start in the left-edge brightness zone belong
                // to that UIKit pan recognizer — skip dismiss so a brightness
                // drag doesn't accidentally close the reader.
                let screenWidth = UIScreen.main.bounds.width
                if value.startLocation.x < screenWidth * ReaderInputHandlers.brightnessZoneFraction {
                    return
                }
                let translation = CGSize(width: value.translation.width,
                                         height: value.translation.height)
                let velocity = CGSize(width: value.predictedEndTranslation.width - value.translation.width,
                                      height: value.predictedEndTranslation.height - value.translation.height)
                if SwipeDismissPolicy.shouldDismiss(translation: translation, velocity: velocity) {
                    dismiss()
                }
            }
    }

    private func loadPublicationIfReady() async {
        guard let book, let fileURL = book.fileURL else { return }
        let id = bookID
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            initialLocator = parseLocator(progress.locatorJSON)
        }
        do {
            let pub = try await openPublication(at: fileURL)
            publication = pub
            await loadScrubMetadata(for: pub)
        } catch {
            let diagnostics = fileDiagnostics(at: fileURL)
            loadError = "Failed to open:\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n\(diagnostics)"
        }
    }

    /// Caches the positions list and TOC→progression map so scrubbing can
    /// resolve progress → Locator and progress → chapter heading without
    /// hitting the publication service on every drag sample. Failures here
    /// degrade gracefully: scrubbing still works (jumps via `positions`) and
    /// the chapter label falls back to an em-dash when TOC is unavailable.
    private func loadScrubMetadata(for publication: Publication) async {
        positions = (try? await publication.positions().get()) ?? []
        let toc = (try? await publication.tableOfContents().get()) ?? []
        let built = buildTOCProgressions(toc: toc, positions: positions)
        tocProgressions = built.progressions
        tocTitlesByHref = built.titlesByHref
    }

    /// Walks the TOC depth-first, mapping each entry to its starting
    /// totalProgression by matching against the first reading-order position
    /// that lives in the same resource. Entries whose href doesn't appear in
    /// the reading order are dropped. Result is sorted ascending so a
    /// linear scan (or future binary search) can find "current chapter" for
    /// a given progression.
    private func buildTOCProgressions(
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

    /// Best-effort chapter title for a Kobo `Location.Source` or Readium
    /// `locator.href`. Tolerates the same prefix/suffix ambiguity as
    /// `buildTOCProgressions`, since locator hrefs may be relative to the
    /// EPUB root while TOC entries are relative to wherever the OPF lives.
    private func chapterTitle(forHref href: String?) -> String? {
        guard let href else { return nil }
        let resource = href.components(separatedBy: "#").first ?? href
        if let exact = tocTitlesByHref[resource] { return exact }
        for (tocHref, title) in tocTitlesByHref where resource.hasSuffix(tocHref) || tocHref.hasSuffix(resource) {
            return title
        }
        return nil
    }

    /// Returns the title of the TOC entry that *starts at or before* the
    /// given whole-book progression. Falls back to an em-dash when the TOC
    /// wasn't loaded or the progression precedes the first mapped entry.
    private func chapterTitle(at progression: Double) -> String {
        guard !tocProgressions.isEmpty else { return "—" }
        var match: String?
        for entry in tocProgressions {
            if entry.progression <= progression {
                match = entry.title
            } else {
                break
            }
        }
        return match ?? tocProgressions.first?.title ?? "—"
    }

    /// Translates a whole-book progression into a Readium `Locator` via the
    /// cached positions list and hands it to the navigator through
    /// `pendingJump`. Keeps `scrubProgress` pinned at the release position so
    /// the bar holds steady until the navigator emits the new locator (cleared
    /// in `onChange(of: currentLocator…)`). No-ops if positions aren't loaded.
    private func commitScrub(to progression: Double) {
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
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            if scrubCommitPending {
                scrubCommitPending = false
                scrubProgress = nil
            }
        }
    }

    private func fileDiagnostics(at url: URL) -> String {
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

    private func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw OpenError.invalidFileURL(url)
        }

        let asset = try await assetRetriever.retrieve(url: fileURL)
            .mapError { OpenError.asset($0) }
            .get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        return try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { OpenError.publication($0) }
            .get()
    }

    private enum OpenError: LocalizedError {
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

    /// Runs in parallel with publication-loading. Network-bound, so the reader
    /// is already on screen by the time this returns. Late-arriving prompts /
    /// silent jumps are suppressed once `userHasNavigated` is true so they
    /// can't yank a user mid-read.
    private func promptTitle(for info: PromptInfo) -> String {
        if let title = chapterTitle(forHref: info.serverHref) {
            return "Another device is in '\(title)' — switch?"
        }
        return "Continue from another device?"
    }

    private func parseHref(_ json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["href"] as? String
    }

    /// Decodes a Readium locator JSON string via the modern `JSONValue` →
    /// `Locator(json:)` path. Used wherever we have a stored or pushed
    /// locator JSON string and need a `Locator` instance.
    private func parseLocator(_ json: String?) -> Locator? {
        guard let json,
              let jsonValue = try? JSONValue(jsonString: json),
              let locator = try? Locator(json: jsonValue, warnings: nil)
        else { return nil }
        return locator
    }

    private func resolveOpen() async {
        guard let book, let sync = env.context(for: book.source.id)?.sync else { return }
        do {
            switch try await sync.onOpen(book: book) {
            case .useLocal:
                break
            case .applyServer(let progress):
                guard !userHasNavigated,
                      let locator = parseLocator(progress.locatorJSON) else { return }
                pendingJumpSource = .resumeFromSync
                pendingJump = locator
            case .promptUser(let local, let server):
                guard !userHasNavigated else { return }
                pendingPrompt = PromptInfo(
                    local: local,
                    server: server,
                    serverHref: parseHref(server.locatorJSON)
                )
            }
        } catch {
            // Best-effort; ignore failures.
        }
    }

    private func currentBook() -> Book? {
        let id = bookID
        return try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func flush() async {
        guard let book = currentBook(),
              let sync = env.context(for: book.source.id)?.sync else { return }
        await sync.flushPendingProgress(for: book)
    }

    /// "Last read 5 min ago on '<device>'" when the server timestamp is real,
    /// or "Last read on '<device>'" when the backend handed us `.distantPast`
    /// (the sentinel for "we don't know when"). Percent isn't shown — Kobo and
    /// Readium compute whole-book progress differently, so the number wouldn't
    /// match the in-app progress bar after navigating.
    private func relativeReadMessage(for progress: CanonicalProgress) -> String {
        let device = "'\(progress.deviceName)'"
        guard progress.timestamp > .distantPast else { return "Last read on \(device)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: progress.timestamp, relativeTo: .now)
        return "Last read \(when) on \(device)"
    }

    /// Pill "Back to p. X" handler: issue a programmatic return to the
    /// stored back-position, tagged so the service ignores it for stats.
    private func handleBackToPage(_ target: ReadingStatsService.JumpReturnTarget) {
        guard target.fromPosition >= 0,
              target.fromPosition < positions.count else {
            env.stats.dismissJumpPill(commitStay: false)
            return
        }
        pendingJumpSource = .programmaticReturn
        pendingJump = positions[target.fromPosition]
        env.stats.dismissJumpPill(commitStay: false)
    }

    /// Toggles a bookmark at the current page. Snapshots the locator JSON
    /// and chapter title at the moment of bookmark so the row survives a
    /// later TOC reload. Plays a selection haptic. No-op when we don't
    /// have a current locator yet.
    private func toggleBookmark() {
        guard let position = currentPositionIndex,
              let locator = currentLocator,
              let json = try? locator.jsonString() else { return }
        BookmarkToggle.toggle(
            in: context,
            bookID: bookID,
            position: position,
            locatorJSON: json,
            chapterTitle: chapterTitleForCurrent
        )
        HapticFeedback.bookmarkToggled()
    }

    private func pushLocator(bookID: UUID, locator: Locator) async {
        let newChapterIdx = chapterIndex(at: locator.locations.totalProgression ?? 0)
        // Seed the baseline on the first (load-artifact) emission so the very
        // next user advance has something to compare against. No haptic fires
        // here because we return before the source/transition check.
        if !initialEmissionSeen {
            initialEmissionSeen = true
            lastSeenChapterIndex = newChapterIdx
            return
        }
        userHasNavigated = true
        guard let book = currentBook() else { return }
        let total = locator.locations.totalProgression ?? 0
        guard let json = try? locator.jsonString() else { return }
        env.context(for: book.source.id)?.sync?.bufferLocator(
            book: book, locatorJSON: json, percentage: total
        )
        // Stats: piggy-back on the same locator callback.
        let source = pendingJumpSource ?? .swipe
        pendingJumpSource = nil
        // Haptic: only on linear (swipe/tap) forward chapter crossings.
        // Non-linear sources (TOC, scrub, AI jump, resume) just refresh the
        // baseline silently so the next linear advance compares correctly.
        if hapticChapterEnabled,
           source.isLinear,
           let prev = lastSeenChapterIndex,
           let new = newChapterIdx,
           new > prev {
            HapticFeedback.chapterChanged()
        }
        lastSeenChapterIndex = newChapterIdx
        if let positionIndex = positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) }) {
            env.stats.sessionDidAdvance(
                position: positionIndex,
                totalPositions: positions.count,
                source: source,
                bookID: book.id
            )
        }
    }
}
