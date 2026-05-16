import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Core

/// Editorial Library screen. Matches `EditorialLibrary`:
///
/// - Large serif **Library** title with trailing search + plus icons
/// - All / Reading / Unread / Finished segmented filter
/// - Three grouped-inset card sections: Reading · Unread · Finished
/// - "Add a book" action sheet on the plus button (Files / URL / Sync now)
///
/// Search is stubbed; "Add from URL" surfaces a "coming soon" alert until the
/// URL importer lands.
struct LibraryRootView: View {

    /// Library tab filter (also used by the segmented control).
    private enum Filter: Hashable {
        case all, reading, unread, finished
    }

    @Query(filter: #Predicate<Book> { !$0.archived },
           sort: \Book.title)
    private var books: [Book]

    @Query private var progresses: [ReadingProgress]

    @Environment(AppEnvironment.self) private var env

    @State private var filter: Filter = .all
    @State private var isRefreshing: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var showAddSheet: Bool = false
    @State private var showURLImportComingSoon: Bool = false
    @State private var importError: String?

    private var progressByBookID: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.bookID, $0.percentage) })
    }

    private var readingBooks: [Book] {
        books.filter { book in
            let p = progressByBookID[book.id] ?? 0
            return book.finishedAt == nil && book.filename != nil && p > 0 && p < 1
        }
    }

    private var unreadBooks: [Book] {
        // Includes both freshly-downloaded books (progress 0) and catalog-only
        // books (filename == nil) so the user can see what's available to read.
        books.filter { book in
            let p = progressByBookID[book.id] ?? 0
            return book.finishedAt == nil && p == 0
        }
    }

    private var finishedBooks: [Book] {
        books.filter { $0.finishedAt != nil }
    }

    /// Footer for the last section — surfaces sync recency. Hidden until the
    /// sync layer exposes a timestamp.
    private var lastSyncedFooter: String? { nil }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    libraryScroll
                }
            }
            .background(EditorialTheme.bg)
            .navigationBarHidden(true)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleImport(result) }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("Coming soon", isPresented: $showURLImportComingSoon) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Importing from a URL isn't supported yet. For now, save the file and use Import EPUB from Files.")
            }
            .confirmationDialog(
                "Add a book",
                isPresented: $showAddSheet,
                titleVisibility: .visible
            ) {
                Button("Import EPUB from Files…") {
                    showFileImporter = true
                }
                Button("Add from URL…") {
                    showURLImportComingSoon = true
                }
                Button("Sync now") {
                    Task {
                        isRefreshing = true
                        try? await env.refreshLibrary()
                        isRefreshing = false
                    }
                }
                .disabled(isRefreshing)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("DRM-free EPUB only. Kios won't ask you to log in to a store.")
            }
        }
    }

    private var libraryScroll: some View {
        ScrollView {
            VStack(spacing: 0) {
                EditorialNavBar(title: "Library") {
                    EditorialNavIconButton(
                        systemName: "magnifyingglass",
                        accessibilityLabel: "Search"
                    ) {
                        // Stub: search isn't implemented yet.
                    }
                    EditorialNavIconButton(
                        systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "plus",
                        accessibilityLabel: "Add book"
                    ) {
                        showAddSheet = true
                    }
                }

                EditorialSegmented(
                    items: [
                        ("All", Filter.all),
                        ("Reading", Filter.reading),
                        ("Unread", Filter.unread),
                        ("Finished", Filter.finished),
                    ],
                    selection: $filter
                )
                .padding(.horizontal, EditorialTheme.listSidePad)

                if isFilteredEmpty {
                    filteredEmptyState
                } else {
                    if filter == .all || filter == .reading, !readingBooks.isEmpty {
                        section("Reading", books: readingBooks, kind: .reading)
                    }
                    if filter == .all || filter == .unread, !unreadBooks.isEmpty {
                        section("Unread", books: unreadBooks, kind: .unread)
                    }
                    if filter == .all || filter == .finished, !finishedBooks.isEmpty {
                        section("Finished",
                                books: finishedBooks,
                                kind: .finished,
                                footer: lastSyncedFooter)
                    }
                }

                Color.clear.frame(height: 110)   // tab-bar breathing
            }
        }
        .refreshable {
            try? await env.refreshLibrary()
        }
    }

    private enum SectionKind { case reading, unread, finished }

    private func section(
        _ name: String,
        books: [Book],
        kind: SectionKind,
        footer: String? = nil
    ) -> some View {
        EditorialList("\(name) · \(books.count)", footer: footer) {
            ForEach(books.indices, id: \.self) { i in
                let book = books[i]
                Button { handleTap(book) } label: {
                    EditorialBookRow(
                        title: book.title,
                        author: book.authors.joined(separator: ", "),
                        progress: progressByBookID[book.id] ?? 0,
                        meta: kind == .unread ? bookMeta(book) : nil,
                        finishedLabel: kind == .finished ? finishedLabel(book) : nil
                    ) {
                        AnyView(BookCoverImage(book: book))
                    }
                }
                .buttonStyle(.plain)
                if i < books.count - 1 {
                    EditorialHairline()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            EditorialNavBar(title: "Library") {
                EditorialNavIconButton(
                    systemName: "plus",
                    accessibilityLabel: "Add book"
                ) {
                    showAddSheet = true
                }
            }
            Spacer()
            ContentUnavailableView(
                "Your library is empty",
                systemImage: "books.vertical",
                description: Text("Tap + to import an EPUB, or pull to refresh.")
            )
            Spacer()
        }
    }

    /// True when the currently-selected filter produces no rows. The `.all`
    /// branch covers the degenerate case where every book is catalog-only
    /// with mid-read progress (and therefore matches none of the three
    /// section predicates) — `books.isEmpty` is handled separately above.
    private var isFilteredEmpty: Bool {
        switch filter {
        case .all:      return readingBooks.isEmpty && unreadBooks.isEmpty && finishedBooks.isEmpty
        case .reading:  return readingBooks.isEmpty
        case .unread:   return unreadBooks.isEmpty
        case .finished: return finishedBooks.isEmpty
        }
    }

    @ViewBuilder
    private var filteredEmptyState: some View {
        let (title, description, symbol) = filteredEmptyContent
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(description)
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.bottom, 80)
    }

    private var filteredEmptyContent: (title: LocalizedStringKey, description: LocalizedStringKey, symbol: String) {
        switch filter {
        case .all:
            return ("Your library is empty",
                    "Tap + to import an EPUB, or pull to refresh.",
                    "books.vertical")
        case .reading:
            return ("Nothing in progress",
                    "Books you start reading will appear here.",
                    "book.pages")
        case .unread:
            return ("No unread books",
                    "Books you haven't started will appear here.",
                    "book.closed")
        case .finished:
            return ("No finished books",
                    "Books you finish reading will appear here.",
                    "checkmark.circle")
        }
    }

    private func bookMeta(_ book: Book) -> String? {
        let format = book.format.rawValue.uppercased()
        guard let url = book.fileURL,
              let size = try? FileManager.default
                  .attributesOfItem(atPath: url.path)[.size] as? Int else {
            return format
        }
        let mb = Double(size) / (1024 * 1024)
        return mb >= 0.1
            ? String(format: "\(format) · %.1f MB", mb)
            : format
    }

    private func finishedLabel(_ book: Book) -> String? {
        guard let finishedAt = book.finishedAt else { return nil }
        return finishedAt.formatted(.dateTime.day().month(.abbreviated))
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let outcome = try await env.localImporter.import(from: url)
                switch outcome {
                case .imported(let book), .existing(let book):
                    env.openReader(book.id)
                }
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func handleTap(_ book: Book) {
        if book.filename != nil {
            env.openReader(book.id)
            return
        }
        // Catalog-only synced book: kick off the download and open the reader.
        // Local books shouldn't reach this branch (they always have a filename).
        guard book.source == .synced, book.acquisitionURL != nil else {
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
