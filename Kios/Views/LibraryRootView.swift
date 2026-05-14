import SwiftUI
import SwiftData
import Core

/// Unified catalog view across sync protocols. Backed by the local
/// SwiftData `Book` store (populated by `LibraryService.refresh`), so the
/// list works identically for kosync and Kobo and is visible offline.
/// Pull-to-refresh re-runs the active protocol's catalog fetch.
struct LibraryRootView: View {
    @Query(filter: #Predicate<Book> { !$0.archived },
           sort: \Book.title)
    private var books: [Book]

    /// Same single-fetch approach as Home — one query, looked up by bookID
    /// per row, instead of N FetchDescriptors.
    @Query private var progresses: [ReadingProgress]

    @Environment(AppEnvironment.self) private var env

    @State private var isRefreshing: Bool = false

    private var progressByBookID: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.bookID, $0.percentage) })
    }

    var body: some View {
        NavigationStack {
            // Always render a List so `.refreshable` has a scrollable parent —
            // the empty state goes inside as an overlay. ContentUnavailableView
            // alone is not scrollable and the pull-to-refresh gesture silently
            // does nothing.
            List(books) { book in
                Button { handleTap(book) } label: {
                    BookRow(book: book,
                            readingProgress: progressByBookID[book.id] ?? 0)
                }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 0, leading: 0,
                                     bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
            }
            .listRowSpacing(0)
            .overlay {
                if books.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "books.vertical",
                        description: Text("Pull to refresh, or tap Refresh.")
                    )
                }
            }
            .refreshable {
                try? await env.refreshLibrary()
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            isRefreshing = true
                            try? await env.refreshLibrary()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh library")
                }
            }
        }
    }

    private func handleTap(_ book: Book) {
        if book.filename != nil {
            env.openReader(book.id)
            return
        }
        // Local books always have filename non-nil (set at import). If we hit
        // this branch with a local book, that's a bug — local books don't
        // have an acquisitionURL to download from.
        guard book.source == .synced, let _ = book.acquisitionURL else {
            return
        }
        Task {
            if book.serverIDProtocol == SyncProtocol.kobo.rawValue {
                await env.refreshAcquisitionURL(for: book)
            }
            _ = try? await env.downloads?.download(book: book)
        }
        env.openReader(book.id)
    }
}
