import Foundation

/// Seam for `ReadingStatsService` so tests can fast-forward without
/// real wall-clock waiting. Production uses `.real`. Tests pass a
/// custom instance with a mutable `nowProvider` and an immediate `sleep`.
struct StatsClock: Sendable {
    var now: @Sendable () -> Date
    /// Suspends for `seconds`. Honors cancellation via `Task.checkCancellation`.
    var sleep: @Sendable (_ seconds: Int) async throws -> Void

    static let real = StatsClock(
        now: { Date() },
        sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) }
    )
}
