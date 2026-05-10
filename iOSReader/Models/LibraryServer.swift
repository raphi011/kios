import Foundation
import SwiftData

@Model
final class LibraryServer {
    @Attribute(.unique) var id: UUID
    var url: URL
    var username: String
    var lastValidatedAt: Date?

    init(id: UUID = UUID(), url: URL, username: String, lastValidatedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.username = username
        self.lastValidatedAt = lastValidatedAt
    }
}
