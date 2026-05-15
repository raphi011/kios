import Foundation
import SwiftData

/// One reading session — the unit of stats truth. Aggregated at read time
/// by `StatsAggregator`. See
/// `docs/superpowers/specs/2026-05-15-reading-stats-reliability-design.md`.
@Model
final class ReadingSession {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var startedAt: Date
    var endedAt: Date
    /// Active time only: sum of "active windows" between page-turns,
    /// each capped at 120 sec. Excludes idle and background time.
    var durationSeconds: Int
    /// Sum of credited linear position deltas during this session.
    /// Only `.swipe`/`.tap` advances within `linearAdvanceThreshold` of
    /// the per-book furthest-linear watermark contribute. By construction
    /// `Σ pagesAdded ≤ book.totalPositions` over a book's lifetime.
    var pagesAdded: Int
    /// Diagnostic: "closed" | "backgrounded" | "idle" | "locked". Not displayed.
    var endReason: String

    init(
        id: UUID,
        bookID: UUID,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        pagesAdded: Int,
        endReason: String
    ) {
        self.id = id
        self.bookID = bookID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.pagesAdded = pagesAdded
        self.endReason = endReason
    }
}
