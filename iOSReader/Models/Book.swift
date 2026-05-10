import Foundation
import SwiftData

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var serverID: String          // OPDS atom:id
    var title: String
    var authors: [String]
    var opdsHref: URL             // detail/entry link
    var acquisitionURL: URL       // direct download
    var format: BookFormat
    var fileURL: URL?             // nil until downloaded
    var partialMD5: String?       // populated after download
    var addedAt: Date

    init(
        id: UUID = UUID(),
        serverID: String,
        title: String,
        authors: [String],
        opdsHref: URL,
        acquisitionURL: URL,
        format: BookFormat,
        fileURL: URL? = nil,
        partialMD5: String? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.authors = authors
        self.opdsHref = opdsHref
        self.acquisitionURL = acquisitionURL
        self.format = format
        self.fileURL = fileURL
        self.partialMD5 = partialMD5
        self.addedAt = addedAt
    }
}
