import SwiftUI
import SwiftData
import UIKit
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
@preconcurrency import ReadiumNavigator
import Core

/// Immersive reader. Presented as a `fullScreenCover` from `RootView`.
///
/// Engine state (publication, locator, scrub, TOC, prompts) lives on
/// `ReaderViewModel`. The view itself holds `@Query`, `@AppStorage`, and
/// pure UI bookkeeping (chrome visibility, HUD percents, selection probe).
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
    /// Persisted by `FontFamilyPickerView`. Empty string = publisher
    /// default (no `EPUBPreferences.fontFamily` override); non-empty =
    /// CSS family name passed through to Readium verbatim.
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ""
    /// On by default. Plays a subtle haptic when a normal swipe/tap crosses
    /// into a new chapter. Silent for TOC jumps, scrubs, and sync-resume —
    /// the toggle gates only linear chapter transitions.
    @AppStorage("reader.hapticChapterEnabled") private var hapticChapterEnabled: Bool = true

    @State private var vm = ReaderViewModel()

    // UI-only state. Engine state (publication, currentLocator, scrub, etc.)
    // lives on `vm`.
    @State private var uiVisible: Bool = false
    /// Set true by the `⊟` button in the reader top bar to present the
    /// Contents / Bookmarks / Notes modal. Setting back to false dismisses.
    @State private var showContents: Bool = false
    @State private var fontHUD: Int? = nil
    /// Percent shown in the brightness HUD (0...100). Driven by the
    /// `onBrightnessUpdate` callback from `ReaderInputHandlers`' UIKit pan
    /// recognizer. `nil` hides the HUD.
    @State private var brightnessHUD: Int? = nil
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

    var body: some View {
        @Bindable var vm = vm

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
            await loadAndResolve()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await flush() }
            }
        }
        .onChange(of: vm.currentLocator?.locations.totalProgression) { _, _ in
            vm.navigatorCaughtUpDuringScrub()
        }
        .onDisappear {
            Task { await flush() }
            env.stats.sessionDidClose(reason: .closed)
            env.router.activeReader = nil
        }
        .fullScreenCover(isPresented: $showContents) {
            contentsModal
        }
    }

    // MARK: - Load + resolve

    /// Runs the publication open + cross-device resolve concurrently, then
    /// opens a stats session once positions are known.
    private func loadAndResolve() async {
        let persistedJSON: String? = {
            let id = bookID
            return try? context.fetch(
                FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
            ).first?.locatorJSON
        }()
        async let load: Void = vm.loadPublication(
            at: book?.fileURL,
            persistedLocatorJSON: persistedJSON
        )
        async let resolve: Void = {
            if let book {
                let sync = env.sources.context(for: book.source.id)?.sync
                await vm.resolveOpen(book: book, sync: sync)
            }
        }()
        _ = await (load, resolve)

        // Stats: open a session once positions are known. Initial position
        // is the current locator's index, falling back to the initial
        // locator, then 0.
        let initialPosition: Int
        if let locator = vm.currentLocator,
           let idx = vm.positions.firstIndex(where: { $0.href.isEquivalentTo(locator.href) }) {
            initialPosition = idx
        } else if let initial = vm.initialLocator,
                  let idx = vm.positions.firstIndex(where: { $0.href.isEquivalentTo(initial.href) }) {
            initialPosition = idx
        } else {
            initialPosition = 0
        }
        if !vm.positions.isEmpty {
            if let book, book.totalPositions != vm.positions.count {
                book.totalPositions = vm.positions.count
                try? context.save()
            }
            env.stats.sessionDidOpen(
                bookID: bookID,
                initialPosition: initialPosition,
                totalPositions: vm.positions.count
            )
        }
    }

    // MARK: - Contents/Bookmarks/Notes data

    /// Builds the contents-modal closure once so the chapter and bookmark
    /// taps share identical jump semantics. Same-position taps short-circuit
    /// to avoid the stale `pendingJumpSource` problem (no locator emission
    /// for an in-place seek).
    @ViewBuilder
    private var contentsModal: some View {
        let jump: (Locator) -> Void = { locator in
            if let target = vm.positionIndex(for: locator),
               let current = vm.currentPositionIndex,
               target == current {
                showContents = false
                return
            }
            vm.pendingJumpSource = .tocJump
            vm.pendingJump = locator
            showContents = false
        }
        ReaderContentsView(
            bookTitle: book?.title ?? "",
            chapters: vm.chapterEntries(for: book),
            bookmarks: bookmarkEntries,
            onJump: jump,
            onJumpToBookmark: jump,
            onDeleteBookmark: { id in deleteBookmark(id: id) },
            onDismiss: { showContents = false }
        )
    }

    /// Maps the persisted Bookmark rows into the view-facing struct.
    /// Bookmarks whose stored locator JSON can no longer be parsed are
    /// dropped — defensive, shouldn't happen in practice. Sorted by
    /// position ascending so the list reads top-to-bottom in book order.
    private var bookmarkEntries: [ReaderContentsView.Bookmark] {
        bookmarksForBook
            .sorted { $0.position < $1.position }
            .compactMap { b in
                guard let loc = ReaderViewModel.parseLocator(b.locatorJSON) else { return nil }
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

    /// True when a bookmark exists for the current page. `bookmarksForBook`
    /// is already filtered by `bookID` in the `@Query` predicate.
    private var isCurrentPageBookmarked: Bool {
        guard let position = vm.currentPositionIndex else { return false }
        return bookmarksForBook.contains { $0.position == position }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let book {
            if book.fileURL != nil, let publication = vm.publication {
                let id = book.id
                // Snapshot href→index outside the @Sendable closure so we
                // don't capture the non-Sendable `Publication`. The reading
                // order is static for the duration of the reader session.
                let chapterIndexByHref: [String: Int] = Dictionary(
                    uniqueKeysWithValues: publication.readingOrder.enumerated().map { ($1.href, $0) }
                )
                ReaderHost(
                    publication: publication,
                    initialLocator: vm.initialLocator,
                    pendingJump: vm.pendingJump,
                    fontSizePct: fontSizePct,
                    fontFamilyRaw: fontFamilyRaw,
                    onLocatorChange: { @Sendable locator in
                        Task { @MainActor in
                            vm.currentLocator = locator
                            handleLocatorChange(locator, chapterIndexByHref: chapterIndexByHref)
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
                    selectionProbe: selectionProbe
                )
                .alert(item: $vm.pendingPrompt) { info in
                    Alert(
                        title: Text(vm.promptTitle(for: info)),
                        message: Text(relativeReadMessage(for: info.server)),
                        primaryButton: .default(Text("Continue")) {
                            vm.acceptPrompt(info)
                        },
                        secondaryButton: .cancel(Text("Stay here"))
                    )
                }
            } else if book.fileURL == nil {
                DownloadingView(book: book, download: download)
            } else if let loadError = vm.loadError {
                Text(loadError).foregroundStyle(.orange).padding()
            } else {
                ProgressView("Opening…").tint(.white)
            }
        } else {
            Text("Book not found").foregroundStyle(.secondary)
        }
    }

    /// Wires a fresh locator emission into sync + stats + the
    /// chapter-watermark side effect. Called on the main actor from the
    /// `@Sendable` `onLocatorChange` after VM state is updated.
    private func handleLocatorChange(_ locator: Locator, chapterIndexByHref: [String: Int]) {
        if let outcome = vm.consumeLocatorChange(locator), let book = books.first {
            if hapticChapterEnabled && outcome.didCrossForwardChapter {
                HapticFeedback.chapterChanged()
            }
            env.sources.context(for: book.source.id)?.sync?.bufferLocator(
                book: book, locatorJSON: outcome.locatorJSON, percentage: outcome.totalProgression
            )
            if let posIdx = outcome.positionIndex {
                env.stats.sessionDidAdvance(
                    position: posIdx,
                    totalPositions: vm.positions.count,
                    source: outcome.advanceSource,
                    bookID: book.id
                )
            }
        }
        // Track furthest chapter the user has reached. Drives "analyze up to
        // here" gating on the Characters tab so spoilers are clipped to the
        // user's read horizon.
        let idx = chapterIndexByHref[locator.href.string] ?? 0
        if let book = books.first, idx > book.maxChapterIndexReached {
            book.maxChapterIndexReached = idx
            try? context.save()
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var chromeOverlay: some View {
        if uiVisible {
            VStack(spacing: 0) {
                EditorialReaderTopBar(
                    title: book?.title ?? "",
                    onLibrary: { dismiss() },
                    isBookmarked: isCurrentPageBookmarked,
                    onToggleBookmark: { toggleBookmark() }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                EditorialReaderBottomBar(
                    chapterTitle: vm.chapterTitleForCurrent,
                    pageLabel: vm.pageLabel,
                    timeLeftLabel: timeLeftLabel,
                    locator: vm.currentLocator,
                    scrubProgress: vm.scrubProgress,
                    tocProgressions: vm.tocProgressions.map(\.progression),
                    resolveChapterTitle: vm.chapterTitle(at:),
                    onScrubUpdate: { progress in vm.setScrubProgress(progress) },
                    onScrubCommit: { progress in vm.commitScrub(to: progress) },
                    onScrubCancel: { vm.cancelScrub() },
                    onContents: { showContents = true }
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .transition(.opacity)
        }
    }

    /// "3h 12m left" — extrapolated from time-so-far × (1 − progress) / progress.
    /// Hidden (nil) until at least one session has landed and the locator is
    /// past 0.1% (the early-extrapolation singularity).
    private var timeLeftLabel: String? {
        let total = sessionsForBook.reduce(0) { $0 + $1.durationSeconds }
        let progress = vm.currentLocator?.locations.totalProgression ?? 0
        guard total > 0, progress > 0.001, progress < 1.0 else { return nil }
        let remaining = Int(Double(total) * (1.0 - progress) / progress)
        return StatsFormatters.time(seconds: remaining) + " left"
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
        } else if let progress = vm.scrubProgress, !vm.scrubCommitPending {
            // HUD belongs to the active drag only. `scrubProgress` is also held
            // post-release to pin the bar at the target position until the
            // navigator emits — but the HUD itself should vanish the moment
            // the finger lifts so the reader isn't left staring at an
            // overlay during the navigator's seek.
            let ctx = vm.chapterContext(at: progress)
            ReaderScrubHUD(
                progress: progress,
                previousChapter2: ctx.previous2,
                previousChapter: ctx.previous1,
                currentChapter: ctx.current,
                nextChapter: ctx.next1,
                nextChapter2: ctx.next2
            )
            .transition(.opacity)
        }
    }

    // MARK: - Gestures

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

    // MARK: - Bookmark + jump-pill side effects

    /// Toggles a bookmark at the current page. Snapshots the locator JSON
    /// and chapter title at the moment of bookmark so the row survives a
    /// later TOC reload. Plays a selection haptic. No-op when we don't
    /// have a current locator yet.
    private func toggleBookmark() {
        guard let position = vm.currentPositionIndex,
              let locator = vm.currentLocator,
              let json = try? locator.jsonString() else { return }
        BookmarkToggle.toggle(
            in: context,
            bookID: bookID,
            position: position,
            locatorJSON: json,
            chapterTitle: vm.chapterTitleForCurrent
        )
        HapticFeedback.bookmarkToggled()
    }

    /// Pill "Back to p. X" handler: ask the VM to issue a programmatic
    /// return, then dismiss the pill. The VM returns `false` for out-of-
    /// range targets (positions may have changed between pill creation and
    /// tap) — in that case we still need to clear the pill.
    private func handleBackToPage(_ target: ReadingStatsService.JumpReturnTarget) {
        _ = vm.handleBackToPage(target)
        env.stats.dismissJumpPill(commitStay: false)
    }

    // MARK: - Sync flush + cross-device prompt formatting

    private func currentBook() -> Book? {
        let id = bookID
        return try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func flush() async {
        guard let book = currentBook(),
              let sync = env.sources.context(for: book.source.id)?.sync else { return }
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
}
