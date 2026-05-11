import SwiftUI
import SwiftData

struct DownloadedRootView: View {
    @Query(filter: #Predicate<Book> { $0.fileURL != nil },
           sort: \Book.title)
    private var books: [Book]

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
                            DownloadedBookRow(book: book)
                        }
                    }
                }
            }
            .navigationTitle("Downloaded")
        }
    }
}

private struct DownloadedBookRow: View {
    let book: Book

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(book.title).font(.headline)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
