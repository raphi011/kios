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
    /// Wall-clock capture time. Not load-bearing for ordering (the list
    /// sorts by `position`) — kept so future surfaces can show a
    /// "saved Tuesday" affordance without a schema bump.
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
