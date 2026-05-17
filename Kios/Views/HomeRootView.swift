import SwiftUI
import SwiftData
import Core

/// Editorial "Today" home screen. Matches the design package's `EditorialHome`:
///
/// - Large serif **Today** title with a dated eyebrow
/// - 3-cell stats card (Read time / Pages / Streak) under a "Today, so far" header
/// - Hero "Continue reading" card with the most-recently-touched book
/// - Editorial book rows for the rest of the library, with a "Last synced" footer
///
/// Search isn't wired yet — the icon is rendered as a stub.
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

    /// Books shown in the "In your library" section: everything except the
    /// hero (so we don't repeat it) and finished books (they belong in the
    /// Library tab's Finished group, not Today's quick list).
    private var libraryPreview: [Book] {
        books.filter { book in
            book.finishedAt == nil && book.id != heroBook?.id
        }
    }

    private var todayEyebrow: String {
        let now = Date.now
        let weekday = now.formatted(.dateTime.weekday(.abbreviated))
        let dayMonth = now.formatted(.dateTime.day().month(.abbreviated))
        return "\(weekday) · \(dayMonth)".uppercased()
    }

    private var statCells: [EditorialStatsCard.Cell] {
        let minutes = stats.todaySeconds / 60
        let pages = stats.todayPages
        let streak = stats.streakDays
        return [
            .init(number: String(minutes), unit: "m", caption: "Read time"),
            .init(number: String(pages), unit: nil, caption: "Pages"),
            .init(number: String(streak), unit: "d", caption: "Streak"),
        ]
    }

    private var lastSyncedFooter: LocalizedStringKey? {
        // Hook for "Last synced N min ago". Real sync timestamps aren't
        // surfaced through AppEnvironment yet, so we hide the footer when no
        // sync has happened in this process. Wire the timestamp through and
        // this lights up automatically.
        nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            EditorialNavBar(title: "Today", eyebrow: todayEyebrow)

                            EditorialList("Today, so far") {
                                EditorialStatsCard(cells: statCells)
                            }

                            if let hero = heroBook {
                                EditorialList("Continue reading") {
                                    EditorialContinueCard(
                                        book: hero,
                                        progress: progressByBookID[hero.id] ?? 0,
                                        sessions: sessions
                                    ) {
                                        env.openReader(hero.id)
                                    }
                                }
                            }

                            if !libraryPreview.isEmpty {
                                EditorialList(
                                    "In your library",
                                    footer: lastSyncedFooter
                                ) {
                                    ForEach(libraryPreview.indices, id: \.self) { i in
                                        let book = libraryPreview[i]
                                        Button {
                                            env.openReader(book.id)
                                        } label: {
                                            EditorialBookRow(
                                                title: book.title,
                                                author: book.authors.joined(separator: ", "),
                                                progress: progressByBookID[book.id] ?? 0,
                                                meta: bookMeta(book),
                                                finishedLabel: nil,
                                                sourceLabel: book.source.displayName
                                            ) {
                                                AnyView(BookCoverImage(book: book))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(book.finishedAt == nil
                                                   ? "Mark as finished"
                                                   : "Mark as unfinished") {
                                                toggleFinished(book)
                                            }
                                            Button("Delete", role: .destructive) {
                                                delete(book)
                                            }
                                        }
                                        if i < libraryPreview.count - 1 {
                                            EditorialHairline()
                                        }
                                    }
                                }
                            }

                            Color.clear.frame(height: 110)   // tab-bar breathing
                        }
                    }
                    .background(EditorialTheme.bg)
                }
            }
            .background(EditorialTheme.bg)
            .navigationBarHidden(true)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No downloaded books",
            systemImage: "books.vertical",
            description: Text("Books you download from Browse appear here.")
        )
        .background(EditorialTheme.bg)
    }

    /// "EPUB · 2.4 MB" when we can read the file; "EPUB" otherwise. Used as
    /// the meta line on un-started books.
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
        // Delegates to LibraryService so the file + Download + ReadingProgress
        // + analysis cascade all happen in one place. Sessions are intentionally
        // preserved as a historical record (see `LibraryService.delete`).
        try? env.library.delete(book: book)
    }
}
