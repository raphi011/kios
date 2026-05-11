import Foundation
import SwiftData
import Core

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var serverID: String          // OPDS atom:id
    var title: String
    var authors: [String]
    var opdsHref: URL             // detail/entry link
    var acquisitionURL: URL       // direct download
    var format: BookFormat
    /// Filename within `AppPaths.booksDirectory`. nil until downloaded.
    ///
    /// We persist only the filename (not an absolute URL) because iOS may
    /// regenerate the app container UUID across reinstalls/redeploys, which
    /// invalidates any absolute file URL stored across launches.
    var filename: String?
    var partialMD5: String?       // populated after download
    /// OPDS thumbnail URL captured at download time so Home can render a cover
    /// without re-fetching the catalog entry. AuthenticatedAsyncImage caches
    /// the bytes via ImageMemoryCache + URLCache.shared.
    var thumbnailURL: URL?
    var addedAt: Date

    init(
        id: UUID = UUID(),
        serverID: String,
        title: String,
        authors: [String],
        opdsHref: URL,
        acquisitionURL: URL,
        format: BookFormat,
        filename: String? = nil,
        partialMD5: String? = nil,
        thumbnailURL: URL? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.authors = authors
        self.opdsHref = opdsHref
        self.acquisitionURL = acquisitionURL
        self.format = format
        self.filename = filename
        self.partialMD5 = partialMD5
        self.thumbnailURL = thumbnailURL
        self.addedAt = addedAt
    }

    /// Resolved absolute file URL, recomputed each access from the live
    /// `AppPaths.booksDirectory`. Predicates and @Query filters must use
    /// `filename`, not this computed property (SwiftData macros only see
    /// stored properties).
    var fileURL: URL? {
        filename.map { AppPaths.booksDirectory.appendingPathComponent($0) }
    }
}
