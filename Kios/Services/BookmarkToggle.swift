import Foundation
import SwiftData

/// Local-only bookmark insert/delete decision against a `ModelContext`.
/// Centralised here so the toggle is unit-testable without a SwiftUI host
/// and without depending on Readium. `ReaderView` calls this on tap of
/// the top-bar bookmark button.
@MainActor
enum BookmarkToggle {
    /// Deletes the bookmark for `(bookID, position)` if it exists; otherwise
    /// inserts a new one with the supplied locator JSON + chapter title.
    /// Saves the context after either branch.
    static func toggle(
        in context: ModelContext,
        bookID: UUID,
        position: Int,
        locatorJSON: String,
        chapterTitle: String
    ) {
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { bookmark in
                bookmark.bookID == bookID && bookmark.position == position
            }
        )
        if let existing = (try? context.fetch(descriptor))?.first {
            context.delete(existing)
        } else {
            context.insert(
                Bookmark(
                    bookID: bookID,
                    position: position,
                    locatorJSON: locatorJSON,
                    chapterTitle: chapterTitle
                )
            )
        }
        try? context.save()
    }
}
