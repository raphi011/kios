import Foundation
import SwiftData

/// One character's appearance in one chapter, written by the per-chapter
/// extraction pass. Append-only during a single analysis run. The explicit
/// `id: UUID` (separate from SwiftData's `PersistentIdentifier`) is what
/// the synthesis pass uses to reference specific mentions in its prompt;
/// `PersistentIdentifier` is opaque and not portable through JSON.
@Model
final class CharacterMention {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var chapterIndex: Int
    var chapterHref: String
    var canonicalName: String
    var aliasesInChapter: [String]
    var descriptionFromChapter: String
    var significance: String          // "major" / "minor" / "mentioned"
    /// Verbatim 10-20 words from the chapter — the jump anchor that
    /// `Publication.searchService.search(_:)` resolves at tap time.
    var quote: String
    /// nil during extraction; set by the synthesis pass to back-link
    /// this mention to its canonical `CharacterProfile`.
    var profileID: UUID?

    init(
        id: UUID,
        bookID: UUID,
        chapterIndex: Int,
        chapterHref: String,
        canonicalName: String,
        aliasesInChapter: [String],
        descriptionFromChapter: String,
        significance: String,
        quote: String,
        profileID: UUID?
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.chapterHref = chapterHref
        self.canonicalName = canonicalName
        self.aliasesInChapter = aliasesInChapter
        self.descriptionFromChapter = descriptionFromChapter
        self.significance = significance
        self.quote = quote
        self.profileID = profileID
    }
}
