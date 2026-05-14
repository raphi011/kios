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
    let onDismiss: () -> Void

    enum Tab: Hashable { case book, chapter, characters }
    @State private var tab: Tab = .book

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var env
    @Query private var analyses: [BookAnalysis]
    @State private var service: BookAnalysisService?

    init(
        bookID: UUID,
        book: Book,
        currentChapterHref: String?,
        makeService: @escaping @MainActor () -> BookAnalysisService,
        onDismiss: @escaping () -> Void
    ) {
        self.bookID = bookID
        self.book = book
        self.currentChapterHref = currentChapterHref
        self.makeService = makeService
        self.onDismiss = onDismiss
        _analyses = Query(filter: #Predicate<BookAnalysis> { $0.bookID == bookID })
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

    /// Per-tab content placeholder. Filled in Task 23.
    private var completedState: some View {
        Text("Completed content for \(String(describing: tab)) — Task 23")
            .foregroundStyle(EditorialTheme.muted)
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
