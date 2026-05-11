import SwiftUI
import SwiftData
import Core

struct BookDetailView: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var downloadError: String?

    init(book: Book) {
        self.book = book
    }

    var body: some View {
        Form {
            Section("Title") { Text(book.title) }
            if !book.authors.isEmpty {
                Section("Authors") {
                    ForEach(book.authors, id: \.self) { Text($0) }
                }
            }
            Section("Format") {
                Text(book.format.rawValue.uppercased())
            }
            actionSection
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if book.fileURL != nil {
                NavigationLink("Open") { ReaderView(bookID: book.id) }
                Button("Remove download", role: .destructive) {
                    remove(book)
                }
            } else {
                Text("Not downloaded")
                    .foregroundStyle(.secondary)
            }
            if let downloadError {
                Text(downloadError).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func remove(_ book: Book) {
        if let url = book.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        book.filename = nil
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
}
