import Foundation
import SwiftData

@Model
final class Bookmark {
    @Attribute(.unique) var id: UUID
    /// Owning book — Book.id. Mirrors ReadingProgress's pattern;
    /// see Models/CONVENTIONS.md for why we store the UUID rather
    /// than the @Model reference.
    var bookID: UUID
    /// 1-based Readium position index. Dedupe key for the toggle
    /// and sort order for the Bookmarks tab.
    var position: Int
    /// Readium Locator JSON captured at bookmark time. Used to jump
    /// back to the exact location (incl. fractional progression).
    var locatorJSON: String
    /// Chapter title snapshotted at creation. Lets the list render
    /// even if the TOC fails to load later.
    var chapterTitle: String
    /// Capture time. Tie-break when two bookmarks share the same position (rare; would only happen across schema-version churn).
    var createdAt: Date

    init(
        id: UUID = UUID(),
        bookID: UUID,
        position: Int,
        locatorJSON: String,
        chapterTitle: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.bookID = bookID
        self.position = position
        self.locatorJSON = locatorJSON
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
    }
}
