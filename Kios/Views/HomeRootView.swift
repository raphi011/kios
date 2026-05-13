import SwiftUI
import SwiftData
import Core

struct HomeRootView: View {
    @Query(filter: #Predicate<Book> { $0.filename != nil },
           sort: \Book.title)
    private var books: [Book]

    @Query private var progresses: [ReadingProgress]
    @Query private var sessions: [ReadingSession]

    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env

    private var progressByBookID: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: progresses.map { ($0.bookID, $0.percentage) })
    }

    private var stats: HomeStats {
        StatsAggregator.compute(sessions: sessions, books: books)
    }

    private var heroBook: Book? {
        StatsAggregator.continueReadingCandidate(
            books: books,
            progressByBookID: progressByBookID,
            sessions: sessions
        )
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
                        Section {
                            StatsHeader(stats: stats)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        if let hero = heroBook {
                            Section {
                                ContinueReadingCard(
                                    book: hero,
                                    progress: progressByBookID[hero.id] ?? 0,
                                    perBookSessions: sessions.filter { $0.bookID == hero.id },
                                    onTap: { env.openReader(hero.id) }
                                )
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        Section("Library") {
                            ForEach(books) { book in
                                Button {
                                    env.openReader(book.id)
                                } label: {
                                    BookRow(book: book,
                                            readingProgress: progressByBookID[book.id] ?? 0)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(.init(top: 0, leading: 16,
                                                     bottom: 0, trailing: 16))
                                .contextMenu {
                                    Button(book.finishedAt == nil
                                           ? "Mark as finished"
                                           : "Mark as unfinished") {
                                        toggleFinished(book)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        delete(book)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Home")
        }
    }

    private func toggleFinished(_ book: Book) {
        if book.finishedAt == nil {
            book.finishedAt = .now
        } else {
            book.finishedAt = nil
        }
        book.finishedManually = true
        try? context.save()
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
        // Sessions for the book are kept (historical record).
        context.delete(book)
        try? context.save()
    }
}
