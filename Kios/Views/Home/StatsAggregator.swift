import Foundation

struct PaceEstimate: Equatable {
    enum Confidence { case medium, high }
    let secondsRemaining: Int
    let confidence: Confidence
}

/// Aggregated stats for the Home tab. `totalSeconds` / `totalPages` are
/// lifetime; `todaySeconds` / `todayPages` are local-day-of-`now`. Both are
/// populated so the strip can switch between "Today, so far" and lifetime
/// without recomputing.
struct HomeStats: Equatable {
    let booksRead: Int
    let totalSeconds: Int
    let totalPages: Int
    let streakDays: Int
    let todaySeconds: Int
    let todayPages: Int

    static let zero = HomeStats(
        booksRead: 0,
        totalSeconds: 0,
        totalPages: 0,
        streakDays: 0,
        todaySeconds: 0,
        todayPages: 0
    )
}

/// Pure aggregation functions over sessions + books. No `Environment`,
/// no `ModelContext`. Tested in isolation.
enum StatsAggregator {

    /// `now` and `calendar` are parameters (not implicit `.current`) so
    /// streak math is deterministic in tests. The streak threshold matches
    /// the spec's 5-min/day floor.
    @MainActor
    static func compute(
        sessions: [ReadingSession],
        books: [Book],
        now: Date = .now,
        calendar: Calendar = .current,
        streakThresholdSeconds: Int = 300
    ) -> HomeStats {
        let booksRead = books.lazy.filter { $0.finishedAt != nil }.count
        let totalSeconds = sessions.reduce(0) { $0 + $1.durationSeconds }
        let totalPages = sessions.reduce(0) { $0 + $1.pagesAdded }
        let streakDays = computeStreak(
            sessions: sessions,
            now: now,
            calendar: calendar,
            threshold: streakThresholdSeconds
        )
        let today = calendar.startOfDay(for: now)
        let todaysSessions = sessions.filter { calendar.startOfDay(for: $0.endedAt) == today }
        let todaySeconds = todaysSessions.reduce(0) { $0 + $1.durationSeconds }
        let todayPages = todaysSessions.reduce(0) { $0 + $1.pagesAdded }
        return HomeStats(
            booksRead: booksRead,
            totalSeconds: totalSeconds,
            totalPages: totalPages,
            streakDays: streakDays,
            todaySeconds: todaySeconds,
            todayPages: todayPages
        )
    }

    /// Walk backward day-by-day from `today`. Start at today only if it
    /// qualifies; otherwise start at yesterday (so an empty/light today
    /// doesn't break an existing streak). Stop at the first non-qualifying day.
    private static func computeStreak(
        sessions: [ReadingSession],
        now: Date,
        calendar: Calendar,
        threshold: Int
    ) -> Int {
        guard !sessions.isEmpty else { return 0 }

        // Bucket sessions by local calendar day.
        var perDay: [Date: Int] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.endedAt)
            perDay[day, default: 0] += session.durationSeconds
        }

        let today = calendar.startOfDay(for: now)
        var cursor: Date
        if (perDay[today] ?? 0) >= threshold {
            cursor = today
        } else {
            // Today empty/light — start at yesterday.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return 0
            }
            cursor = yesterday
        }

        var count = 0
        while (perDay[cursor] ?? 0) >= threshold {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    /// Per-book "X min left" estimate. Returns nil when (a) the book's
    /// totalPositions hasn't been populated yet (publication never opened
    /// in the reader on this device), or (b) per-book trusted reading is
    /// under 5 minutes. Blends a per-book pace with a lifetime pace as
    /// confidence climbs from 5 to 30 minutes. Clamps the working pace to
    /// [1.5s, 60s] per position so pathological scrub/idle sessions can't
    /// drag the estimate to extremes. Anchors the "where the user is"
    /// position on `max(furthestLinearPosition, cursor)` so a post-scrub
    /// cursor doesn't make the estimate undercount remaining time.
    @MainActor
    static func paceEstimate(
        bookID: UUID,
        progressFraction: Double,
        book: Book,
        sessions: [ReadingSession]
    ) -> PaceEstimate? {
        guard book.totalPositions > 0 else { return nil }

        let trusted = sessions.filter { $0.pagesAdded > 0 }
        let perBook = trusted.filter { $0.bookID == bookID }
        let perBookSeconds = perBook.reduce(0) { $0 + $1.durationSeconds }
        let perBookPages = perBook.reduce(0) { $0 + $1.pagesAdded }
        let perBookMinutes = perBookSeconds / 60

        guard perBookMinutes >= 5, perBookPages > 0 else { return nil }

        let globalSeconds = trusted.reduce(0) { $0 + $1.durationSeconds }
        let globalPages = trusted.reduce(0) { $0 + $1.pagesAdded }
        let defaultPace = 1.5  // seconds per position, ~250 WPM
        let globalPace = globalPages > 0
            ? clamp(Double(globalSeconds) / Double(globalPages), 1.5, 60.0)
            : defaultPace
        let perBookPace = clamp(Double(perBookSeconds) / Double(perBookPages), 1.5, 60.0)

        let alpha = clamp((Double(perBookMinutes) - 5.0) / 25.0, 0.2, 0.8)
        let blendedPace = alpha * perBookPace + (1 - alpha) * globalPace

        let cursorPosition = Int(progressFraction * Double(book.totalPositions))
        let anchorPosition = max(book.furthestLinearPosition, cursorPosition)
        let remainingPositions = max(book.totalPositions - anchorPosition, 0)
        let secondsRemaining = Int(blendedPace * Double(remainingPositions))

        return PaceEstimate(
            secondsRemaining: secondsRemaining,
            confidence: perBookMinutes >= 30 ? .high : .medium
        )
    }

    private static func clamp<T: Comparable>(_ value: T, _ lo: T, _ hi: T) -> T {
        min(max(value, lo), hi)
    }

    /// Most-recently-touched eligible book. nil when no book qualifies.
    ///
    /// Eligibility: downloaded (`filename != nil`), not archived,
    /// not finished, progress in `[0, 0.95)`. (Progress `== 0` is allowed so
    /// fresh downloads appear in the hero before the first session lands.)
    @MainActor
    static func continueReadingCandidate(
        books: [Book],
        progressByBookID: [UUID: Double],
        sessions: [ReadingSession]
    ) -> Book? {
        let latestSessionByBookID: [UUID: Date] = Dictionary(
            sessions.map { ($0.bookID, $0.endedAt) },
            uniquingKeysWith: max
        )

        let eligible = books.filter { book in
            guard book.filename != nil,
                  book.archived == false,
                  book.finishedAt == nil else { return false }
            let p = progressByBookID[book.id] ?? 0
            return p < 0.95
        }

        // `max(by:)` keeps the FIRST tied maximum. We want input-order
        // stability where the LATER element wins ties (so callers can
        // pre-sort by their own secondary key). Enumerate so the index
        // becomes an implicit tie-breaker.
        return eligible.enumerated().max(by: { lhs, rhs in
            let l = latestSessionByBookID[lhs.element.id] ?? lhs.element.addedAt
            let r = latestSessionByBookID[rhs.element.id] ?? rhs.element.addedAt
            if l != r { return l < r }
            return lhs.offset < rhs.offset
        })?.element
    }
}
