import Foundation
import SwiftData

/// One reading session — the unit of stats truth. Aggregated at read time
/// by `StatsAggregator`. See `docs/superpowers/specs/2026-05-13-reading-stats-design.md`.
@Model
final class ReadingSession {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var startedAt: Date
    var endedAt: Date
    /// Active time only: sum of "active windows" between page-turns,
    /// each capped at 120 sec. Excludes idle and background time.
    var durationSeconds: Int
    var minPosition: Int
    var maxPosition: Int
    /// `max(maxPosition - minPosition, 0)` — counts advancement, not re-reads.
    /// Stored (not derived) so home-tab aggregation is a single-pass sum.
    var pagesAdded: Int
    /// Diagnostic: "closed" | "backgrounded" | "idle" | "locked". Not displayed.
    var endReason: String

    init(
        id: UUID,
        bookID: UUID,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        minPosition: Int,
        maxPosition: Int,
        pagesAdded: Int,
        endReason: String
    ) {
        self.id = id
        self.bookID = bookID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.minPosition = minPosition
        self.maxPosition = maxPosition
        self.pagesAdded = pagesAdded
        self.endReason = endReason
    }
}
