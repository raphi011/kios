import Foundation
import SwiftData
import Core

@MainActor
final class LibraryService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Reconciles the local Book store with a fresh catalog snapshot.
    ///
    /// Matches existing rows by exact identity first (koboBookUUID, then
    /// partialMD5), falling back to normalized title+authors. Missing
    /// identity fields are filled but never overwritten — once a download
    /// has minted a local `partialMD5`, that value is canonical and the
    /// catalog's claim does not supersede it. Books absent from the catalog
    /// are archived (soft-deleted) rather than removed so future re-appearances
    /// can un-archive and preserve user state like ReadingProgress rows.
    ///
    /// `activeProtocol` stamps `serverIDProtocol` only on newly-inserted rows.
    /// Matched books keep their original protocol — identity is merged across
    /// protocols, not flipped.
    func refresh(using catalog: any CatalogBackend, activeProtocol: SyncProtocol) async throws {
        let entries = try await catalog.listLibrary()
        let existing = try context.fetch(FetchDescriptor<Book>())
        var matchedIDs: Set<UUID> = []

        for entry in entries {
            if let book = Self.matchBook(in: existing, to: entry) {
                if let md5 = entry.identity.partialMD5, book.partialMD5 == nil {
                    book.partialMD5 = md5
                }
                if let uuid = entry.identity.koboBookUUID, book.koboBookUUID == nil {
                    book.koboBookUUID = uuid
                }
                // Un-archive on re-appearance so a book restored on the server
                // comes back to the main shelf without manual intervention.
                book.archived = false
                matchedIDs.insert(book.id)
            } else {
                let new = Book(
                    serverID: entry.serverID,
                    serverIDProtocol: activeProtocol.rawValue,
                    title: entry.title,
                    authors: entry.authors,
                    opdsHref: nil,
                    acquisitionURL: entry.downloadURL,
                    format: entry.format,
                    koboBookUUID: entry.identity.koboBookUUID,
                    archived: false,
                    partialMD5: entry.identity.partialMD5,
                    thumbnailURL: entry.thumbnailURL
                )
                context.insert(new)
                matchedIDs.insert(new.id)
            }
        }

        for book in existing where !matchedIDs.contains(book.id) {
            book.archived = true
        }

        try context.save()
    }

    /// Match priority: exact koboBookUUID, then exact partialMD5, then
    /// normalized (lowercase, alphanumeric-only) title plus sorted authors.
    /// Format is intentionally NOT part of the match — cross-protocol books
    /// often differ in container (EPUB vs KEPUB) but represent the same work.
    static func matchBook(in existing: [Book], to entry: CatalogEntry) -> Book? {
        if let uuid = entry.identity.koboBookUUID,
           let match = existing.first(where: { $0.koboBookUUID == uuid }) {
            return match
        }
        if let md5 = entry.identity.partialMD5,
           let match = existing.first(where: { $0.partialMD5 == md5 }) {
            return match
        }
        let entryTitle = normalize(entry.title)
        let entryAuthors = entry.authors.map(normalize).sorted()
        return existing.first { book in
            normalize(book.title) == entryTitle &&
            book.authors.map(normalize).sorted() == entryAuthors
        }
    }

    /// Lowercase + strip non-alphanumeric. Robust to punctuation drift,
    /// whitespace, and case differences across catalog sources. Diacritics
    /// are intentionally not normalized — users care about visual match.
    ///
    /// `nonisolated` because this is a pure function — it must be callable
    /// from synchronous, non-MainActor test contexts without hopping actors.
    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
