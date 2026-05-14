import Foundation
import SwiftData

/// Persisted AI-generated summary of one EPUB chapter. Keyed by a composite
/// ID that includes the engine, so swapping between `foundationModels` and
/// `gemma4_e4b` produces independent rows for the same chapter.
///
/// The typed `makeID(bookID:chapterHref:engine:)` helper lives in
/// `Kios/Services/AI/ChapterSummary+ID.swift` so this @Model file stays free of
/// `Core` / AI-engine dependencies — the `KiosControls` app extension shares
/// this file via the schema and does not need (or have) those types in scope.
@Model
final class ChapterSummary {
    @Attribute(.unique) var id: String
    var bookID: UUID
    var chapterHref: String
    var engine: String      // AIEngine.rawValue
    var text: String
    var createdAt: Date
    var sourceHash: String

    init(
        id: String,
        bookID: UUID,
        chapterHref: String,
        engine: String,
        text: String,
        createdAt: Date,
        sourceHash: String
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterHref = chapterHref
        self.engine = engine
        self.text = text
        self.createdAt = createdAt
        self.sourceHash = sourceHash
    }
}
