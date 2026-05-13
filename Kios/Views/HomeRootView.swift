import SwiftUI
import SwiftData
import Core

struct HomeRootView: View {
    @Query(filter: #Predicate<Book> { $0.filename != nil },
           sort: \Book.title)
    private var books: [Book]

    /// All progress rows for downloaded books. We do a single fetch instead of
    /// one @Query per row — keeps the row view body simple and avoids creating
    /// N FetchDescriptors for an N-book library.
    @Query private var progresses: [ReadingProgress]

    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env

    private var progressByBookID: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.bookID, $0.percentage) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "No downloaded books",
                        systemImage: "books.vertical",
                        description: Text("Books you download from Browse appear here.")
                    )
                } else {
                    List {
                        ForEach(books) { book in
                            Button {
                                env.openReader(book.id)
                            } label: {
                                BookRow(book: book,
                                        readingProgress: progressByBookID[book.id] ?? 0)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(.init(top: 0, leading: 0,
                                                 bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(book)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listRowSpacing(0)
                }
            }
            .navigationTitle("Home")
        }
    }

    private func delete(_ book: Book) {
        if let url = book.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
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
        context.delete(book)
        try? context.save()
    }
}
