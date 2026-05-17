import Foundation
import SwiftData
import Core

@Model
final class Book {
    @Attribute(.unique) var id: UUID

    /// The source this book belongs to (one of the user's configured servers,
    /// or the singleton Local source for imported files).
    var source: Source

    /// Backend-assigned identity (OPDS atom:id for kosync, RevisionId for Kobo).
    /// Nil for local books that have not been auto-promoted to a server source.
    var serverID: String?

    /// Sync protocol that minted `serverID`. Currently "kosync" or "kobo".
    /// Nil for local books that have not been auto-promoted.
    var serverIDProtocol: String?

    var title: String
    var authors: [String]

    /// OPDS detail/entry link. Nil for Kobo books, which lack an OPDS entry,
    /// and nil for local books.
    var opdsHref: URL?

    /// Direct download URL. Nil for local books that have not been
    /// auto-promoted.
    var acquisitionURL: URL?

    var format: BookFormat

    /// Filename within `AppPaths.booksDirectory`. nil until downloaded
    /// (server) or imported (local).
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
    /// without re-fetching the catalog entry. Nil for local books, which
    /// store their cover bytes locally via `coverFilename`.
    var thumbnailURL: URL?

    /// Local cover-image filename within `AppPaths.booksDirectory`. Populated
    /// only for local books, extracted by Readium at import. Format is jpg.
    var coverFilename: String?

    var addedAt: Date

    /// Soft-delete flag used by Kobo. Never set for local books — they
    /// live outside the catalog's authority.
    var archived: Bool

    /// Set when the user has read the book to ≥95% progression (auto)
    /// or via the row's "Mark as finished" context menu (manual).
    /// nil means "not finished".
    var finishedAt: Date?

    /// `true` once the user has explicitly toggled finished/unfinished.
    /// Locks out auto-95% detection.
    var finishedManually: Bool = false

    /// Largest position ever credited as a linear page-read for this book,
    /// or the largest position reached via .resumeFromSync (sync trust).
    /// Monotonically non-decreasing. Defaults to 0.
    ///
    /// See `docs/superpowers/specs/2026-05-15-reading-stats-reliability-design.md`.
    var furthestLinearPosition: Int = 0

    /// Count of Readium "positions" in this publication. Populated by
    /// `ReaderView` the first time the publication loads. `0` means
    /// "not yet known" — the pace estimator hides its output in that case.
    var totalPositions: Int = 0

    /// Highest reading-order chapter index the user has ever loaded. Monotonic —
    /// never decreases. Bumped in `ReaderView.onLocatorChange`. Source of truth
    /// for spoiler-aware filtering in the Characters tab.
    var maxChapterIndexReached: Int = 0

    init(
        id: UUID = UUID(),
        source: Source,
        serverID: String? = nil,
        serverIDProtocol: String? = nil,
        title: String,
        authors: [String],
        opdsHref: URL? = nil,
        acquisitionURL: URL? = nil,
        format: BookFormat,
        koboBookUUID: String? = nil,
        archived: Bool = false,
        filename: String? = nil,
        partialMD5: String? = nil,
        thumbnailURL: URL? = nil,
        coverFilename: String? = nil,
        addedAt: Date = .now,
        finishedAt: Date? = nil,
        finishedManually: Bool = false
    ) {
        self.id = id
        self.source = source
        self.serverID = serverID
        self.serverIDProtocol = serverIDProtocol
        self.title = title
        self.authors = authors
        self.opdsHref = opdsHref
        self.acquisitionURL = acquisitionURL
        self.format = format
        self.koboBookUUID = koboBookUUID
        self.filename = filename
        self.partialMD5 = partialMD5
        self.thumbnailURL = thumbnailURL
        self.coverFilename = coverFilename
        self.addedAt = addedAt
        self.archived = archived
        self.finishedAt = finishedAt
        self.finishedManually = finishedManually
        self.furthestLinearPosition = 0
        self.totalPositions = 0
        self.maxChapterIndexReached = 0
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
