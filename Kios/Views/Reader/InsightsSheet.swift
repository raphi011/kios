// Kios/Views/Reader/InsightsSheet.swift
import SwiftUI
import SwiftData

/// Sheet presented from the reader's bottom bar. Three tabs:
///   • Book      — whole-book summary card
///   • Chapter   — current chapter summary
///   • Characters — profile list + per-character detail screen
///
/// All tabs share one underlying `BookAnalysis` row. When no analysis has
/// run yet, every tab shows an "Analyze book" empty state. While analysis
/// is in progress, all tabs show a unified progress UI. After completion,
/// each tab renders its tab-specific cached row.
struct InsightsSheet: View {
    let bookID: UUID
    let book: Book
    /// Href of the chapter the reader is currently viewing — drives the
    /// Chapter tab's lookup.
    let currentChapterHref: String?
    /// Closure that constructs the service with the live `Publication`
    /// already baked in. Built once by `ReaderView`.
    let makeService: @MainActor () -> BookAnalysisService
    /// Reader-side jump handler invoked from `CharacterDetailScreen` when the
    /// user taps a quoted mention. Wired by `ReaderView` in Task 24.
    let onJumpRequest: (String, String) -> Void
    let onDismiss: () -> Void

    enum Tab: Hashable { case book, chapter, characters }
    @State private var tab: Tab = .book
    @State private var showCharactersFullBook = false

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var env
    @Query private var analyses: [BookAnalysis]
    @Query private var bookSummaries: [BookSummary]
    @Query private var allChapterSummaries: [ChapterSummary]
    @Query private var profiles: [CharacterProfile]
    @State private var service: BookAnalysisService?

    init(
        bookID: UUID,
        book: Book,
        currentChapterHref: String?,
        makeService: @escaping @MainActor () -> BookAnalysisService,
        onJumpRequest: @escaping (String, String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.bookID = bookID
        self.book = book
        self.currentChapterHref = currentChapterHref
        self.makeService = makeService
        self.onJumpRequest = onJumpRequest
        self.onDismiss = onDismiss
        _analyses = Query(filter: #Predicate<BookAnalysis> { $0.bookID == bookID })
        _bookSummaries = Query(filter: #Predicate<BookSummary> { $0.bookID == bookID })
        _allChapterSummaries = Query(filter: #Predicate<ChapterSummary> { $0.bookID == bookID })
        _profiles = Query(
            filter: #Predicate<CharacterProfile> { $0.bookID == bookID },
            sort: \.earliestChapterIndex
        )
    }

    private var analysis: BookAnalysis? { analyses.first }

    private enum DerivedState { case none, inProgress, failed, completed, stale }

    private var state: DerivedState {
        guard let a = analysis else { return .none }
        if a.schemaVersion < BookAnalysis.currentSchemaVersion { return .stale }
        switch a.status {
        case "in_progress": return .inProgress
        case "failed":      return .failed
        case "completed":   return .completed
        default:            return .none
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                    .padding(.horizontal, EditorialTheme.rowSidePad)
                    .padding(.top, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contentForState
                    }
                    .padding(EditorialTheme.rowSidePad)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { onDismiss() }
                }
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var tabPicker: some View {
        EditorialSegmented(
            items: [
                (label: "Book",       value: Tab.book),
                (label: "Chapter",    value: Tab.chapter),
                (label: "Characters", value: Tab.characters),
            ],
            selection: $tab
        )
    }

    @ViewBuilder
    private var contentForState: some View {
        switch state {
        case .none:       emptyState
        case .inProgress: inProgressState
        case .failed:     failedState
        case .completed:  completedState
        case .stale:      staleState
        }
    }

    // MARK: - Per-state views

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 32)
            Text("Analyze this book to extract a roster, per-chapter summaries, and a whole-book overview.")
                .font(EditorialTheme.sans(size: 15))
                .foregroundStyle(EditorialTheme.muted)
                .multilineTextAlignment(.center)
            Button(action: startAnalysis) {
                Text("Analyze book")
                    .font(EditorialTheme.sans(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 9).fill(EditorialTheme.accent))
            }
            .buttonStyle(.plain)
            Text("Roughly 5 min on iPhone 17 Pro; longer on older devices.")
                .font(EditorialTheme.sans(size: 12))
                .foregroundStyle(EditorialTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }

    private var inProgressState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = analysis {
                Text("Analyzing chapter \(a.chaptersCompleted + 1) of \(a.chaptersTotal)…")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                ProgressView(value: Double(a.chaptersCompleted), total: Double(max(a.chaptersTotal, 1)))
                    .tint(EditorialTheme.accent)
                Button(action: { service?.cancel() }) {
                    Text("Cancel")
                        .font(EditorialTheme.sans(size: 13, weight: .medium))
                        .foregroundStyle(EditorialTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let a = analysis {
                Text("Analysis stopped")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(EditorialTheme.danger)
                if let reason = a.failureReason {
                    Text(reason)
                        .font(EditorialTheme.sans(size: 13))
                        .foregroundStyle(EditorialTheme.muted)
                }
                HStack {
                    primaryButton("Resume") { Task { await resumeAnalysis() } }
                    Button(action: { Task { await restartAnalysis() } }) {
                        Text("Restart")
                            .font(EditorialTheme.sans(size: 14, weight: .semibold))
                            .foregroundStyle(EditorialTheme.danger)
                            .frame(maxWidth: .infinity).frame(height: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var staleState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This analysis is from an older version of the app.")
                .font(EditorialTheme.sans(size: 13))
                .foregroundStyle(EditorialTheme.muted)
            primaryButton("Re-analyze") { Task { await restartAnalysis() } }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var completedState: some View {
        switch tab {
        case .book:       bookTab
        case .chapter:    chapterTab
        case .characters: charactersTab
        }
    }

    @ViewBuilder
    private var bookTab: some View {
        if let summary = bookSummary {
            Text(summary.text)
                .font(EditorialTheme.serif(size: 16))
                .foregroundStyle(EditorialTheme.ink)
                .lineSpacing(4)
        } else {
            Text("No book summary yet.")
                .font(EditorialTheme.sans(size: 14))
                .foregroundStyle(EditorialTheme.muted)
        }
    }

    @ViewBuilder
    private var chapterTab: some View {
        if let href = currentChapterHref, let summary = chapterSummary(for: href) {
            Text(summary.text)
                .font(EditorialTheme.serif(size: 16))
                .foregroundStyle(EditorialTheme.ink)
                .lineSpacing(4)
        } else {
            Text("No summary for this chapter — try analyzing again.")
                .font(EditorialTheme.sans(size: 14))
                .foregroundStyle(EditorialTheme.muted)
        }
    }

    @ViewBuilder
    private var charactersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSegmented(
                items: [
                    (label: "Through what you've read", value: false),
                    (label: "Full book",                value: true),
                ],
                selection: $showCharactersFullBook
            )
            ForEach(visibleProfiles, id: \.id) { profile in
                NavigationLink {
                    CharacterDetailScreen(
                        profileID: profile.id,
                        bookID: bookID,
                        book: book,
                        onJump: onJumpRequest,
                        onDismissSheet: onDismiss
                    )
                } label: {
                    profileRow(profile)
                }
                .buttonStyle(.plain)
                EditorialHairline()
            }
        }
    }

    private func profileRow(_ p: CharacterProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.canonicalName)
                    .font(EditorialTheme.serif(size: 17, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                Text("Appears in chapter \(p.earliestChapterIndex + 1)–\(p.latestChapterIndex + 1)")
                    .font(EditorialTheme.mono(size: 11))
                    .foregroundStyle(EditorialTheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
        .padding(.vertical, 8)
    }

    private var bookSummary: BookSummary? { bookSummaries.first }

    private func chapterSummary(for href: String) -> ChapterSummary? {
        allChapterSummaries.first { $0.chapterHref == href }
    }

    private var visibleProfiles: [CharacterProfile] {
        let dataCap = analysis?.chaptersCompleted ?? 0
        let cap = showCharactersFullBook ? dataCap : min(book.maxChapterIndexReached, dataCap)
        return profiles.filter { $0.earliestChapterIndex <= cap }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(EditorialTheme.sans(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(EditorialTheme.accent))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func startAnalysis() {
        guard let engine = currentEngine() else { return }
        let svc = service ?? makeService()
        service = svc
        Task { try? await svc.start(bookID: bookID, engine: engine) }
    }

    private func resumeAnalysis() async {
        guard let engine = currentEngine() else { return }
        let svc = service ?? makeService()
        service = svc
        try? await svc.resume(bookID: bookID, engine: engine)
    }

    private func restartAnalysis() async {
        guard let engine = currentEngine() else { return }
        let svc = service ?? makeService()
        service = svc
        try? await svc.restart(bookID: bookID, engine: engine)
    }

    private func currentEngine() -> AIEngine? {
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
}
