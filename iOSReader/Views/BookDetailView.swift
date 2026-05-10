import SwiftUI
import SwiftData

struct BookDetailView: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var downloading = false
    @State private var downloadError: String?

    var body: some View {
        Group {
            if let book = fetchBook() {
                content(for: book)
            } else {
                Text("Book not found")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fetchBook() -> Book? {
        let id = bookID
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    @ViewBuilder
    private func content(for book: Book) -> some View {
        Form {
            Section("Title") {
                Text(book.title)
            }
            if !book.authors.isEmpty {
                Section("Authors") {
                    ForEach(book.authors, id: \.self) { Text($0) }
                }
            }
            Section("Format") {
                Text(book.format.rawValue.uppercased())
            }
            Section {
                if book.fileURL == nil {
                    Button {
                        Task { await download(book) }
                    } label: {
                        if downloading {
                            ProgressView()
                        } else {
                            Text("Download")
                        }
                    }
                    .disabled(downloading)
                } else {
                    NavigationLink("Open") {
                        ReaderView(bookID: book.id)
                    }
                    Button("Remove download", role: .destructive) {
                        remove(book)
                    }
                }
                if let downloadError {
                    Text(downloadError).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func download(_ book: Book) async {
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
        // Drop the Download row (frees the unique key slot for re-download).
        if let download = try? context.fetch(
            FetchDescriptor<Download>(predicate: #Predicate { $0.bookID == id })
        ).first {
            context.delete(download)
        }
        // Drop the ReadingProgress row (so re-download starts fresh from the server).
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            context.delete(progress)
        }
        try? context.save()
    }
}
