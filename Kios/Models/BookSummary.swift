import Foundation
import SwiftData

/// Whole-book summary produced by the analyze pipeline's final
/// map-reduce pass. Keyed by `bookID` — one row per book per
/// successful analysis. Engine identity is captured for diagnostics
/// (e.g., showing the user "summarized by Built-in").
@Model
final class BookSummary {
    @Attribute(.unique) var bookID: UUID
    var engine: String          // AIEngine.rawValue
    var text: String
    var createdAt: Date

    init(
        bookID: UUID,
        engine: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.bookID = bookID
        self.engine = engine
        self.text = text
        self.createdAt = createdAt
    }
}
