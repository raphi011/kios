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
/// Subviews live in `Kios/Views/Library/`:
/// - `LibrarySearchBar`, `LibraryGallerySection`, `LibraryListSection`,
///   `LibraryEmptyState`, `LibraryFilteredEmptyState`, `LibrarySearchEmptyState`
/// - `LibraryFilter` enum + `LibraryClassifier` for the pure filter logic.
struct LibraryRootView: View {

    @Query(filter: #Predicate<Book> { !$0.archived },
           sort: \Book.title)
    private var books: [Book]

    @Query private var progresses: [ReadingProgress]

    @Query(sort: [SortDescriptor(\Source.sortOrder)]) private var allSources: [Source]

    @Environment(AppEnvironment.self) private var env

    @AppStorage("library.selectedSourceID") private var selectedSourceIDString: String?

    @State private var filter: LibraryFilter = .all
    @State private var isRefreshing: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var showAddSheet: Bool = false
    @State private var showURLImportComingSoon: Bool = false
    @State private var importError: String?

    /// Persists the user's preferred presentation across launches.
    /// `false` = the editorial row list; `true` = a covers-only grid.
    @AppStorage(.libraryGalleryMode) private var galleryMode: Bool

    @State private var searchActive: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    // MARK: - Derived state

    private var selectedSource: Source? {
        if let id = selectedSourceIDString.flatMap(UUID.init(uuidString:)),
           let match = allSources.first(where: { $0.id == id }) {
            return match
        }
        return allSources.first(where: { $0.kind != .local })
            ?? allSources.first(where: { $0.kind == .local })
    }

    private var booksInSelectedSource: [Book] {
        guard let source = selectedSource else { return books }
        return books.filter { $0.source.id == source.id }
    }

    /// Whitespace-trimmed, lowercased query; empty when nothing's typed.
    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Books matching the active query in title or any author.
    private var searchResults: [Book] {
        let q = normalizedQuery
        guard !q.isEmpty else { return [] }
        return booksInSelectedSource.filter { book in
            book.title.lowercased().contains(q)
                || book.authors.contains { $0.lowercased().contains(q) }
        }
    }

    private var isSearching: Bool { searchActive && !normalizedQuery.isEmpty }

    private var progressByBookID: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.bookID, $0.percentage) })
    }

    private var readingBooks: [Book] {
        LibraryClassifier.reading(booksInSelectedSource, progressByBookID: progressByBookID)
    }
    private var unreadBooks: [Book] {
        LibraryClassifier.unread(booksInSelectedSource, progressByBookID: progressByBookID)
    }
    private var finishedBooks: [Book] {
        LibraryClassifier.finished(booksInSelectedSource)
    }

    /// True when the currently-selected filter produces no rows.
    private var isFilteredEmpty: Bool {
        switch filter {
        case .all:      return readingBooks.isEmpty && unreadBooks.isEmpty && finishedBooks.isEmpty
        case .reading:  return readingBooks.isEmpty
        case .unread:   return unreadBooks.isEmpty
        case .finished: return finishedBooks.isEmpty
        }
    }

    /// Footer for the last section — surfaces sync recency. Hidden until the
    /// sync layer exposes a timestamp.
    private var lastSyncedFooter: LocalizedStringKey? { nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if booksInSelectedSource.isEmpty {
                    LibraryEmptyState { showAddSheet = true }
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
                        guard let src = selectedSource else { return }
                        isRefreshing = true
                        try? await env.refreshLibrary(source: src)
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

    // MARK: - Library scroll

    private var libraryScroll: some View {
        ScrollView {
            VStack(spacing: 0) {
                navBar
                if searchActive {
                    LibrarySearchBar(
                        query: $searchQuery,
                        focused: $searchFocused,
                        onCancel: closeSearch
                    )
                }
                if !searchActive {
                    EditorialSegmented(
                        items: [
                            ("All", LibraryFilter.all),
                            ("Reading", LibraryFilter.reading),
                            ("Unread", LibraryFilter.unread),
                            ("Finished", LibraryFilter.finished),
                        ],
                        selection: $filter
                    )
                    .padding(.horizontal, EditorialTheme.listSidePad)
                }
                contentSections
                Color.clear.frame(height: 110)   // tab-bar breathing
            }
        }
        .refreshable {
            guard let src = selectedSource else { return }
            try? await env.refreshLibrary(source: src)
        }
    }

    private var navBar: some View {
        EditorialNavBar(titleContent: { SourcePickerHeader() }) {
            EditorialNavIconButton(
                systemName: galleryMode ? "list.bullet" : "square.grid.2x2",
                accessibilityLabel: galleryMode ? "List view" : "Gallery view"
            ) {
                galleryMode.toggle()
            }
            EditorialNavIconButton(
                systemName: "magnifyingglass",
                accessibilityLabel: "Search"
            ) {
                toggleSearch()
            }
            EditorialNavIconButton(
                systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "plus",
                accessibilityLabel: "Add book"
            ) {
                showAddSheet = true
            }
        }
    }

    @ViewBuilder
    private var contentSections: some View {
        if isSearching {
            if searchResults.isEmpty {
                LibrarySearchEmptyState(query: searchQuery)
            } else if galleryMode {
                LibraryGallerySection(
                    title: "Results", books: searchResults, onTap: handleTap
                )
                .padding(.top, 8)
            } else {
                LibraryListSection(
                    title: "Results",
                    books: searchResults,
                    kind: .reading,
                    progressByBookID: progressByBookID,
                    metaForBook: bookMeta,
                    finishedLabelForBook: finishedLabel,
                    onTap: handleTap
                )
            }
        } else if searchActive {
            // Search bar shown but query is empty — leave space.
            Spacer().frame(height: 40)
        } else if isFilteredEmpty {
            LibraryFilteredEmptyState(filter: filter)
        } else if galleryMode {
            galleryBody
        } else {
            listBody
        }
    }

    @ViewBuilder
    private var galleryBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            if filter == .all || filter == .reading, !readingBooks.isEmpty {
                LibraryGallerySection(title: "Reading", books: readingBooks, onTap: handleTap)
            }
            if filter == .all || filter == .unread, !unreadBooks.isEmpty {
                LibraryGallerySection(title: "Unread", books: unreadBooks, onTap: handleTap)
            }
            if filter == .all || filter == .finished, !finishedBooks.isEmpty {
                LibraryGallerySection(title: "Finished", books: finishedBooks, onTap: handleTap)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var listBody: some View {
        if filter == .all || filter == .reading, !readingBooks.isEmpty {
            LibraryListSection(
                title: "Reading", books: readingBooks, kind: .reading,
                progressByBookID: progressByBookID,
                metaForBook: bookMeta, finishedLabelForBook: finishedLabel,
                onTap: handleTap
            )
        }
        if filter == .all || filter == .unread, !unreadBooks.isEmpty {
            LibraryListSection(
                title: "Unread", books: unreadBooks, kind: .unread,
                progressByBookID: progressByBookID,
                metaForBook: bookMeta, finishedLabelForBook: finishedLabel,
                onTap: handleTap
            )
        }
        if filter == .all || filter == .finished, !finishedBooks.isEmpty {
            LibraryListSection(
                title: "Finished", books: finishedBooks, kind: .finished,
                footer: lastSyncedFooter,
                progressByBookID: progressByBookID,
                metaForBook: bookMeta, finishedLabelForBook: finishedLabel,
                onTap: handleTap
            )
        }
    }

    // MARK: - Search controls

    private func toggleSearch() {
        if searchActive {
            closeSearch()
        } else {
            searchActive = true
            // Focus on the next runloop so the field is in the tree first.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func closeSearch() {
        searchActive = false
        searchQuery = ""
        searchFocused = false
    }

    // MARK: - Row metadata

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

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let outcome = try await env.localImporter.import(
                    from: url,
                    localSource: env.localSource
                )
                switch outcome {
                case .imported(let book), .existing(let book):
                    env.router.openReader(book.id)
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
            env.router.openReader(book.id)
            return
        }
        // Catalog-only server book: kick off the download and open the reader.
        // Local books shouldn't reach this branch (they always have a filename).
        guard book.source.kind != .local, book.acquisitionURL != nil else {
            return
        }
        Task {
            if book.serverIDProtocol == SyncProtocol.kobo.rawValue {
                await env.refreshAcquisitionURL(for: book)
            }
            _ = try? await env.sources.context(for: book.source.id)?.downloads?.download(book: book)
        }
        env.router.openReader(book.id)
    }
}
