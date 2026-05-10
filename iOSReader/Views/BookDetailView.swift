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
        try? context.save()
    }
}

/// Stub — replaced by Task 5.5.
struct ReaderView: View {
    let bookID: UUID
    var body: some View {
        Text("Reader (stub) for \(bookID)")
            .navigationTitle("Reader")
    }
}
