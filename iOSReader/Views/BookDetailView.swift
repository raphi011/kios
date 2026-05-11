import SwiftUI
import SwiftData
import Core

struct BookDetailView: View {
    /// Source kind. Browse passes an entry; Downloaded passes a SwiftData book.
    enum Source: Equatable {
        case entry(AcquisitionEntry)
        case book(Book)
        case legacy(UUID)
    }

    let source: Source

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var selectedFormat: BookFormat?
    @State private var downloading = false
    @State private var downloadError: String?

    init(entry: AcquisitionEntry) {
        self.source = .entry(entry)
    }

    init(book: Book) {
        self.source = .book(book)
    }

    /// Legacy. Deleted in Task 14 along with LibraryView.
    /// LibraryView still calls this; resolves to `.book(...)` inside the body
    /// via findBookByLocalID. Returns a "not found" view if the id no longer
    /// resolves.
    // TODO(Task 14): delete with LibraryView
    init(bookID: UUID) {
        self.source = .legacy(bookID)
    }

    var body: some View {
        Group {
            switch source {
            case .legacy(let id):
                if let book = Self.findBookByLocalID(id, context: context) {
                    detail(forResolvedBook: book, sourceAcquisitions: [
                        Acquisition(href: book.acquisitionURL, mimeType: "", format: book.format)
                    ])
                } else {
                    Text("Book not found").foregroundStyle(.secondary)
                }
            case .entry, .book:
                detail(forResolvedBook: localBook,
                       sourceAcquisitions: acquisitions)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detail(forResolvedBook resolvedBook: Book?,
                        sourceAcquisitions: [Acquisition]) -> some View {
        Form {
            Section("Title") { Text(title) }
            if !authors.isEmpty {
                Section("Authors") {
                    ForEach(authors, id: \.self) { Text($0) }
                }
            }
            formatSection(acquisitions: sourceAcquisitions)
            actionSection(resolvedBook: resolvedBook,
                          sourceAcquisitions: sourceAcquisitions)
        }
    }

    // MARK: - Derived

    private var localBook: Book? {
        switch source {
        case .book(let b): return b
        case .entry(let e): return Self.findBook(serverID: e.serverID, context: context)
        case .legacy(let id): return Self.findBookByLocalID(id, context: context)
        }
    }

    private var title: String {
        switch source {
        case .book(let b): return b.title
        case .entry(let e): return e.title
        case .legacy(let id):
            return Self.findBookByLocalID(id, context: context)?.title ?? ""
        }
    }

    private var authors: [String] {
        switch source {
        case .book(let b): return b.authors
        case .entry(let e): return e.authors
        case .legacy(let id):
            return Self.findBookByLocalID(id, context: context)?.authors ?? []
        }
    }

    private var acquisitions: [Acquisition] {
        switch source {
        case .entry(let e): return e.acquisitions
        case .book(let b):
            return [Acquisition(href: b.acquisitionURL, mimeType: "", format: b.format)]
        case .legacy(let id):
            if let book = Self.findBookByLocalID(id, context: context) {
                return [Acquisition(href: book.acquisitionURL, mimeType: "", format: book.format)]
            }
            return []
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func formatSection(acquisitions: [Acquisition]) -> some View {
        if acquisitions.count > 1 {
            Section("Format") {
                Picker("Format", selection: Binding(
                    get: { selectedFormat ?? acquisitions[0].format },
                    set: { selectedFormat = $0 }
                )) {
                    ForEach(acquisitions) { acq in
                        Text(acq.format.rawValue.uppercased()).tag(acq.format)
                    }
                }
                .pickerStyle(.segmented)
            }
        } else if let only = acquisitions.first {
            Section("Format") {
                Text(only.format.rawValue.uppercased())
            }
        }
    }

    @ViewBuilder
    private func actionSection(resolvedBook: Book?,
                               sourceAcquisitions: [Acquisition]) -> some View {
        Section {
            if let book = resolvedBook, book.fileURL != nil {
                NavigationLink("Open") { ReaderView(bookID: book.id) }
                Button("Remove download", role: .destructive) {
                    remove(book)
                }
            } else {
                Button {
                    Task { await download(sourceAcquisitions: sourceAcquisitions) }
                } label: {
                    if downloading { ProgressView() } else { Text("Download") }
                }
                .disabled(downloading || sourceAcquisitions.isEmpty)
            }
            if let downloadError {
                Text(downloadError).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func download(sourceAcquisitions: [Acquisition]) async {
        guard case .entry(let entry) = source else { return }
        let chosen = sourceAcquisitions.first {
            $0.format == (selectedFormat ?? sourceAcquisitions[0].format)
        } ?? sourceAcquisitions[0]
        let book = Self.upsertBook(entry: entry, chosen: chosen, context: context)
        downloading = true
        defer { downloading = false }
        do {
            _ = try await env.downloads?.download(book: book)
            downloadError = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func remove(_ book: Book) {
        if let url = book.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        book.fileURL = nil
        book.partialMD5 = nil

        let id = book.id
        if let download = try? context.fetch(
            FetchDescriptor<Download>(predicate: #Predicate { $0.bookID == id })
        ).first {
            context.delete(download)
        }
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            context.delete(progress)
        }
        try? context.save()
    }

    // MARK: - Helpers (static for testability)

    static func findBook(serverID: String, context: ModelContext) -> Book? {
        let id = serverID
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.serverID == id }
        )
        return try? context.fetch(descriptor).first
    }

    static func findBookByLocalID(_ id: UUID, context: ModelContext) -> Book? {
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    static func upsertBook(entry: AcquisitionEntry, chosen: Acquisition,
                           context: ModelContext) -> Book {
        if let existing = findBook(serverID: entry.serverID, context: context) {
            existing.title = entry.title
            existing.authors = entry.authors
            existing.acquisitionURL = chosen.href
            existing.opdsHref = chosen.href
            existing.format = chosen.format
            return existing
        }
        let book = Book(
            serverID: entry.serverID,
            title: entry.title,
            authors: entry.authors,
            opdsHref: chosen.href,
            acquisitionURL: chosen.href,
            format: chosen.format
        )
        context.insert(book)
        try? context.save()
        return book
    }
}
