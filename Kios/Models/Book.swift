// Kios/Models/Book.swift
import Foundation
import SwiftData
import Core

@Model
final class Book {
    @Attribute(.unique) var id: UUID

    /// Where this book came from. `.synced` means the catalog is authoritative
    /// for `serverID` / `serverIDProtocol` / `acquisitionURL`. `.local` means
    /// the user imported the file directly; catalog fields are nil until
    /// auto-promotion on a partialMD5 catalog match.
    var source: BookSource = BookSource.synced

    /// Backend-assigned identity (OPDS atom:id for kosync, RevisionId for Kobo).
    /// Nil for `.local` books that have not been auto-promoted to `.synced`.
    var serverID: String?

    /// Sync protocol that minted `serverID`. Currently "kosync" or "kobo".
    /// Nil for `.local` books that have not been auto-promoted.
    var serverIDProtocol: String?

    var title: String
    var authors: [String]

    /// OPDS detail/entry link. Nil for Kobo books, which lack an OPDS entry,
    /// and nil for `.local` books.
    var opdsHref: URL?

    /// Direct download URL. Nil for `.local` books that have not been
    /// auto-promoted.
    var acquisitionURL: URL?

    var format: BookFormat

    /// Filename within `AppPaths.booksDirectory`. nil until downloaded
    /// (synced) or imported (local).
    ///
    /// We persist only the filename (not an absolute URL) because iOS may
    /// regenerate the app container UUID across reinstalls/redeploys, which
    /// invalidates any absolute file URL stored across launches.
    var filename: String?

    var partialMD5: String?       // populated after download/import

    /// Kobo book identifier (UUID string). Populated for books minted by the
    /// Kobo sync backend; nil for kosync and local books.
    var koboBookUUID: String?

    /// OPDS thumbnail URL captured at download time so Home can render a cover
    /// without re-fetching the catalog entry. Nil for `.local` books, which
    /// store their cover bytes locally via `coverFilename`.
    var thumbnailURL: URL?

    /// Local cover-image filename within `AppPaths.booksDirectory`. Populated
    /// only for `.local` books, extracted by Readium at import. Format is jpg.
    var coverFilename: String?

    var addedAt: Date

    /// Soft-delete flag used by Kobo. Never set for `.local` books — they
    /// live outside the catalog's authority.
    var archived: Bool

    /// Set when the user has read the book to ≥95% progression (auto)
    /// or via the row's "Mark as finished" context menu (manual).
    /// nil means "not finished".
    var finishedAt: Date?

    /// `true` once the user has explicitly toggled finished/unfinished.
    /// Locks out auto-95% detection.
    var finishedManually: Bool = false

    /// Convenience init for synced books. Mirrors the pre-V2 signature so most
    /// call sites compile unchanged.
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
        self.source = .synced
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
        self.coverFilename = nil
        self.addedAt = addedAt
        self.archived = archived
        self.finishedAt = finishedAt
        self.finishedManually = finishedManually
    }

    /// Convenience init for locally-imported books. Catalog fields default to
    /// nil and `archived` defaults to false. Callers populate `filename`,
    /// `partialMD5`, and `coverFilename` after the import pipeline completes.
    init(
        source: BookSource,
        id: UUID = UUID(),
        title: String,
        authors: [String],
        format: BookFormat,
        filename: String? = nil,
        partialMD5: String? = nil,
        coverFilename: String? = nil,
        addedAt: Date = .now
    ) {
        precondition(source == .local, "use the catalog initializer for synced books")
        self.id = id
        self.source = source
        self.serverID = nil
        self.serverIDProtocol = nil
        self.title = title
        self.authors = authors
        self.opdsHref = nil
        self.acquisitionURL = nil
        self.format = format
        self.filename = filename
        self.partialMD5 = partialMD5
        self.koboBookUUID = nil
        self.thumbnailURL = nil
        self.coverFilename = coverFilename
        self.addedAt = addedAt
        self.archived = false
        self.finishedAt = nil
        self.finishedManually = false
    }

    /// Resolved absolute file URL, recomputed each access from the live
    /// `AppPaths.booksDirectory`. Predicates and @Query filters must use
    /// `filename`, not this computed property.
    var fileURL: URL? {
        filename.map { AppPaths.booksDirectory.appendingPathComponent($0) }
    }

    /// Resolved absolute cover-file URL for local books.
    var coverFileURL: URL? {
        coverFilename.map { AppPaths.booksDirectory.appendingPathComponent($0) }
    }

    /// Canonical sync-layer identity for this book, used to talk to a
    /// `SyncBackend` without exposing protocol-specific fields.
    var identity: BookIdentity {
        BookIdentity(partialMD5: partialMD5, koboBookUUID: koboBookUUID)
    }
}
