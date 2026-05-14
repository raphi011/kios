import Foundation
import SwiftData

/// One row per analyzed book. Owns pipeline state for a single analysis
/// run; resume / restart writes to the same row instead of creating a
/// sibling. Engine swap means user re-analyzes and overwrites.
@Model
final class BookAnalysis {
    @Attribute(.unique) var bookID: UUID
    var engine: String                  // AIEngine.rawValue
    var schemaVersion: Int
    var status: String                  // "in_progress" / "completed" / "failed"
    var chaptersCompleted: Int
    var chaptersTotal: Int
    var startedAt: Date
    var completedAt: Date?
    var failureReason: String?

    init(
        bookID: UUID,
        engine: String,
        chaptersTotal: Int,
        schemaVersion: Int = BookAnalysis.currentSchemaVersion,
        status: String = "in_progress",
        chaptersCompleted: Int = 0,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.bookID = bookID
        self.engine = engine
        self.chaptersTotal = chaptersTotal
        self.schemaVersion = schemaVersion
        self.status = status
        self.chaptersCompleted = chaptersCompleted
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failureReason = failureReason
    }
}

extension BookAnalysis {
    /// Bump when prompt templates or output structure change in a way that
    /// invalidates previously persisted analyses. Reading a row with
    /// `schemaVersion < currentSchemaVersion` should treat it as stale and
    /// prompt the user to re-analyze.
    static let currentSchemaVersion = 1
}
