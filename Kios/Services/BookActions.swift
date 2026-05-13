import Foundation
import SwiftData
import Core

/// Static helpers for finding and creating Book rows. v1 supports one row per
/// (serverID, format) combo — so a book downloaded in EPUB + PDF appears as
/// two distinct Book rows in SwiftData (and twice in Home).
enum BookActions {
    /// Returns the Book row for a specific (serverID, format), or nil.
    ///
    /// SwiftData's #Predicate macro does not support enum-value comparisons
    /// reliably in Swift 5.10 / iOS 17 (including rawValue paths on @Model
    /// stored properties). We fetch all rows for the serverID and filter
    /// in-memory instead — the set is always tiny (≤ BookFormat.allCases.count).
    static func findBook(serverID: String, format: BookFormat,
                         context: ModelContext) -> Book? {
        findAllBooks(serverID: serverID, context: context)
            .first { $0.format == format }
    }

    /// Returns all Book rows for a serverID, across all formats.
    static func findAllBooks(serverID: String, context: ModelContext) -> [Book] {
        let id = serverID
        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.serverID == id }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Upserts a Book for (entry.serverID, chosen.format). Updates metadata if
    /// the row exists; creates it otherwise. The returned Book is always in
    /// the context (insert is implicit on creation; caller saves).
    static func upsertBook(entry: AcquisitionEntry, chosen: Acquisition,
                           context: ModelContext) -> Book {
        if let existing = findBook(serverID: entry.serverID,
                                   format: chosen.format, context: context) {
            existing.title = entry.title
            existing.authors = entry.authors
            existing.acquisitionURL = chosen.href
            existing.opdsHref = chosen.href
            existing.thumbnailURL = entry.thumbnailURL
            return existing
        }
        let book = Book(
            serverID: entry.serverID,
            serverIDProtocol: "kosync",
            title: entry.title,
            authors: entry.authors,
            opdsHref: chosen.href,
            acquisitionURL: chosen.href,
            format: chosen.format,
            koboBookUUID: nil,
            archived: false,
            thumbnailURL: entry.thumbnailURL
        )
        context.insert(book)
        try? context.save()
        return book
    }
}
