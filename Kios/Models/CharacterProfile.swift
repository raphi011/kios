import Foundation
import SwiftData

/// Canonical character merged across all per-chapter mentions in one book.
/// Written by the synthesis pass at the end of `BookAnalysisService.start`.
/// Multiple `CharacterMention.profileID` values back-link to one of these.
///
/// `synthesizedDescription` is the full-book version; the spoiler-free
/// description shown in `CharacterDetailScreen` is computed at render time
/// from per-chapter `CharacterMention.descriptionFromChapter` strings.
@Model
final class CharacterProfile {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var canonicalName: String
    var allAliases: [String]
    var synthesizedDescription: String
    var earliestChapterIndex: Int
    var latestChapterIndex: Int

    init(
        id: UUID,
        bookID: UUID,
        canonicalName: String,
        allAliases: [String],
        synthesizedDescription: String,
        earliestChapterIndex: Int,
        latestChapterIndex: Int
    ) {
        self.id = id
        self.bookID = bookID
        self.canonicalName = canonicalName
        self.allAliases = allAliases
        self.synthesizedDescription = synthesizedDescription
        self.earliestChapterIndex = earliestChapterIndex
        self.latestChapterIndex = latestChapterIndex
    }
}
