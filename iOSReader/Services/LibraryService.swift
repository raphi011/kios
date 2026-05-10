import Foundation
import SwiftData

struct BookListItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let authors: [String]
    let format: BookFormat
    let state: State

    enum State: Equatable, Sendable {
        case remote
        case downloading(progress: Double)
        case downloaded(fileURL: URL, partialMD5: String)
        case failed(message: String)
    }
}

@MainActor
protocol LibraryServiceProtocol: AnyObject {
    func refresh() async throws
    var items: [BookListItem] { get }
    var observableItems: AsyncStream<[BookListItem]> { get }
}

@MainActor
final class LibraryService: LibraryServiceProtocol {
    private let opds: OPDSClientProtocol
    private let context: ModelContext
    private let rootURL: URL

    private(set) var items: [BookListItem] = []
    private var continuation: AsyncStream<[BookListItem]>.Continuation?
    let observableItems: AsyncStream<[BookListItem]>

    init(opds: OPDSClientProtocol, context: ModelContext, rootURL: URL) {
        self.opds = opds
        self.context = context
        self.rootURL = rootURL
        var c: AsyncStream<[BookListItem]>.Continuation!
        self.observableItems = AsyncStream { c = $0 }
        self.continuation = c
        rebuildItems()
    }

    func refresh() async throws {
        var url: URL? = rootURL.appendingPathComponent("opds/")
        while let nextURL = url {
            let catalog = try await opds.fetchCatalog(url: nextURL)
            try mergeCatalog(catalog)
            url = catalog.nextURL
        }
        rebuildItems()
    }

    // MARK: - private

    private func mergeCatalog(_ catalog: OPDSCatalog) throws {
        for entry in catalog.entries {
            let serverID = entry.serverID
            let descriptor = FetchDescriptor<Book>(
                predicate: #Predicate { $0.serverID == serverID }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.title = entry.title
                existing.authors = entry.authors
                existing.acquisitionURL = entry.acquisitionURL
                existing.format = entry.format
            } else {
                context.insert(Book(
                    serverID: serverID,
                    title: entry.title,
                    authors: entry.authors,
                    opdsHref: entry.detailURL ?? entry.acquisitionURL,
                    acquisitionURL: entry.acquisitionURL,
                    format: entry.format
                ))
            }
        }
        try context.save()
    }

    private func rebuildItems() {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let downloads = (try? context.fetch(FetchDescriptor<Download>())) ?? []
        let downloadByID = Dictionary(uniqueKeysWithValues: downloads.map { ($0.bookID, $0) })

        items = books.map { book in
            let state: BookListItem.State
            if let url = book.fileURL, let md5 = book.partialMD5 {
                state = .downloaded(fileURL: url, partialMD5: md5)
            } else if let dl = downloadByID[book.id] {
                switch dl.state {
                case .running:
                    let p = dl.totalBytes > 0
                        ? Double(dl.bytesReceived) / Double(dl.totalBytes)
                        : 0
                    state = .downloading(progress: p)
                case .failed:
                    state = .failed(message: dl.error ?? "Download failed")
                case .idle, .completed:
                    state = .remote
                }
            } else {
                state = .remote
            }
            return BookListItem(
                id: book.id,
                title: book.title,
                authors: book.authors,
                format: book.format,
                state: state
            )
        }
        continuation?.yield(items)
    }
}
