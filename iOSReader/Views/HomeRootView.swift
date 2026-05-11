import SwiftUI
import SwiftData

struct HomeRootView: View {
    @Query(filter: #Predicate<Book> { $0.fileURL != nil },
           sort: \Book.title)
    private var books: [Book]

    /// All progress rows for downloaded books. We do a single fetch instead of
    /// one @Query per row — keeps the row view body simple and avoids creating
    /// N FetchDescriptors for an N-book library.
    @Query private var progresses: [ReadingProgress]

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
                    List(books) { book in
                        NavigationLink {
                            BookDetailView(book: book)
                        } label: {
                            HomeBookRow(book: book,
                                        progress: progressByBookID[book.id] ?? 0)
                        }
                    }
                }
            }
            .navigationTitle("Home")
        }
    }
}

private struct HomeBookRow: View {
    let book: Book
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    FormatChip(format: book.format)
                    if progress > 0 {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 120)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct FormatChip: View {
    let format: BookFormat

    var body: some View {
        Text(format.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            )
            .foregroundStyle(.secondary)
    }
}
