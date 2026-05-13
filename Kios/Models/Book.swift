import Foundation
import SwiftData
import Core

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    /// Backend-assigned identity (OPDS atom:id for kosync, RevisionId for Kobo).
    var serverID: String
    /// Sync protocol that minted `serverID`. Currently "kosync" or "kobo".
    var serverIDProtocol: String
    var title: String
    var authors: [String]
    /// OPDS detail/entry link. Nil for Kobo books, which lack an OPDS entry.
    var opdsHref: URL?
    var acquisitionURL: URL       // direct download
    var format: BookFormat
    /// Filename within `AppPaths.booksDirectory`. nil until downloaded.
    ///
    /// We persist only the filename (not an absolute URL) because iOS may
    /// regenerate the app container UUID across reinstalls/redeploys, which
    /// invalidates any absolute file URL stored across launches.
    var filename: String?
    var partialMD5: String?       // populated after download
    /// Kobo book identifier (UUID string). Populated for books minted by the
    /// Kobo sync backend; nil for kosync books.
    var koboBookUUID: String?
    /// OPDS thumbnail URL captured at download time so Home can render a cover
    /// without re-fetching the catalog entry. AuthenticatedAsyncImage caches
    /// the bytes via ImageMemoryCache + URLCache.shared.
    var thumbnailURL: URL?
    var addedAt: Date
    /// Soft-delete flag used by Kobo (which models archive instead of delete).
    var archived: Bool
    /// Set when the user has read the book to ≥95% progression (auto)
    /// or via the row's "Mark as finished" context menu (manual).
    /// nil means "not finished".
    var finishedAt: Date?
    /// `true` once the user has explicitly toggled finished/unfinished.
    /// Locks out auto-95% detection so an un-finished book doesn't
    /// re-finish itself on the next read past 95%.
    var finishedManually: Bool = false

    init(
        id: UUID = UUID(),
        serverID: String,
        serverIDProtocol: String,
        title: String,
        authors: [String],
        opdsHref: URL?,
        acquisitionURL: URL,
        format: BookFormat,
        koboBookUUID: String?,
        archived: Bool,
        filename: String? = nil,
        partialMD5: String? = nil,
        thumbnailURL: URL? = nil,
        addedAt: Date = .now,
        finishedAt: Date? = nil,
        finishedManually: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.serverIDProtocol = serverIDProtocol
        self.title = title
        self.authors = authors
        self.opdsHref = opdsHref
        self.acquisitionURL = acquisitionURL
        self.format = format
        self.filename = filename
        self.partialMD5 = partialMD5
        self.koboBookUUID = koboBookUUID
        self.thumbnailURL = thumbnailURL
        self.addedAt = addedAt
        self.archived = archived
        self.finishedAt = finishedAt
        self.finishedManually = finishedManually
    }

    /// Resolved absolute file URL, recomputed each access from the live
    /// `AppPaths.booksDirectory`. Predicates and @Query filters must use
    /// `filename`, not this computed property (SwiftData macros only see
    /// stored properties).
    var fileURL: URL? {
        filename.map { AppPaths.booksDirectory.appendingPathComponent($0) }
    }

    /// Canonical sync-layer identity for this book, used to talk to a
    /// `SyncBackend` without exposing protocol-specific fields.
    var identity: BookIdentity {
        BookIdentity(partialMD5: partialMD5, koboBookUUID: koboBookUUID)
    }
}
