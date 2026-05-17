import Foundation
import SwiftData

enum SourceKind: String, Codable, Sendable, CaseIterable {
    case local
    case opdsReadOnly
    case kosync
    case kobo
}

@Model
final class Source {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var kind: SourceKind
    /// Catalog/sync server URL. `nil` for `.local`.
    var serverURL: URL?
    /// User-visible ordering in pickers + Settings list. Server sources
    /// sort ascending; Local is forced to last by view logic regardless.
    var sortOrder: Int
    var createdAt: Date
    /// Set by lifecycle code when the initial refresh / sync fails so the
    /// Settings row can surface a banner. Cleared on a successful refresh.
    var needsAttention: Bool = false

    /// Cascade-deleting books-by-source relationship. Removing a `Source`
    /// removes every `Book` that referenced it (used by `LibraryService`'s
    /// per-source removal flow).
    @Relationship(deleteRule: .cascade, inverse: \Book.source)
    var books: [Book] = []

    init(
        id: UUID = UUID(),
        displayName: String,
        kind: SourceKind,
        serverURL: URL?,
        sortOrder: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.serverURL = serverURL
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
