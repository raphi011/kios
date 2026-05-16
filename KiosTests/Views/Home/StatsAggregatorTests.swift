// KiosTests/Views/Home/StatsAggregatorTests.swift
import Testing
import Foundation
@testable import Kios

@MainActor
@Suite("StatsAggregator")
struct StatsAggregatorTests {

    // MARK: helpers

    private static let utc = TimeZone(identifier: "UTC")!
    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.utc
        return c
    }

    /// 2026-05-13 12:00:00 UTC as a fixed reference "now".
    private static let now = Date(timeIntervalSince1970: 1_778_673_600)

    private static func day(_ daysAgo: Int, secondsIntoDay: Int = 12 * 3600) -> Date {
        let dayStart = Self.utcCalendar.startOfDay(
            for: now.addingTimeInterval(TimeInterval(-86_400 * daysAgo))
        )
        return dayStart.addingTimeInterval(TimeInterval(secondsIntoDay))
    }

    private static func session(
        bookID: UUID = UUID(),
        endedAt: Date,
        durationSeconds: Int,
        pagesAdded: Int = 0
    ) -> ReadingSession {
        ReadingSession(
            id: UUID(),
            bookID: bookID,
            startedAt: endedAt.addingTimeInterval(-TimeInterval(durationSeconds)),
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            pagesAdded: pagesAdded,
            endReason: "closed"
        )
    }

    private static func book(
        id: UUID = UUID(),
        filename: String? = "x.epub",
        archived: Bool = false,
        finishedAt: Date? = nil,
        addedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Book {
        let b = Book(
            serverID: id.uuidString,
            serverIDProtocol: "kosync",
            title: "T",
            authors: [],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub,
            koboBookUUID: nil,
            archived: archived,
            filename: filename,
            addedAt: addedAt,
            finishedAt: finishedAt
        )
        b.id = id
        return b
    }

    // MARK: compute()

    @Test func emptyInputYieldsZeros() {
        let stats = StatsAggregator.compute(
            sessions: [],
            books: [],
            now: Self.now,
            calendar: Self.utcCalendar
        )
        #expect(stats.booksRead == 0)
        #expect(stats.totalSeconds == 0)
        #expect(stats.totalPages == 0)
        #expect(stats.streakDays == 0)
    }

    @Test func sumsTotalsAcrossSessions() {
        let s1 = Self.session(endedAt: Self.day(0), durationSeconds: 100, pagesAdded: 3)
        let s2 = Self.session(endedAt: Self.day(1), durationSeconds: 200, pagesAdded: 5)
        let stats = StatsAggregator.compute(
            sessions: [s1, s2], books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.totalSeconds == 300)
        #expect(stats.totalPages == 8)
    }

    @Test func countsFinishedBooks() {
        let b1 = Self.book(finishedAt: nil)
        let b2 = Self.book(finishedAt: Self.now)
        let b3 = Self.book(finishedAt: Self.now)
        let stats = StatsAggregator.compute(
            sessions: [], books: [b1, b2, b3],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.booksRead == 2)
    }

    @Test func streakCountsThreeConsecutiveQualifyingDays() {
        // Each day has ≥300s of reading.
        let sessions = [
            Self.session(endedAt: Self.day(0), durationSeconds: 400),
            Self.session(endedAt: Self.day(1), durationSeconds: 400),
            Self.session(endedAt: Self.day(2), durationSeconds: 400),
        ]
        let stats = StatsAggregator.compute(
            sessions: sessions, books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.streakDays == 3)
    }

    @Test func streakStopsAtFirstNonQualifyingDay() {
        // Today and yesterday qualify; 2 days ago is below the threshold.
        let sessions = [
            Self.session(endedAt: Self.day(0), durationSeconds: 400),
            Self.session(endedAt: Self.day(1), durationSeconds: 400),
            Self.session(endedAt: Self.day(2), durationSeconds: 60),  // < 300s
            Self.session(endedAt: Self.day(3), durationSeconds: 400),
        ]
        let stats = StatsAggregator.compute(
            sessions: sessions, books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.streakDays == 2)
    }

    @Test func todayEmptyDoesNotBreakStreak() {
        // Streak runs yesterday + day-before. Today has no reading.
        let sessions = [
            Self.session(endedAt: Self.day(1), durationSeconds: 400),
            Self.session(endedAt: Self.day(2), durationSeconds: 400),
        ]
        let stats = StatsAggregator.compute(
            sessions: sessions, books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        // Today doesn't qualify yet, but doesn't break the existing streak.
        #expect(stats.streakDays == 2)
    }

    @Test func todayBelowThresholdDoesNotBreakStreakButDoesNotExtendEither() {
        let sessions = [
            Self.session(endedAt: Self.day(0), durationSeconds: 60),    // today, < 300s
            Self.session(endedAt: Self.day(1), durationSeconds: 400),
            Self.session(endedAt: Self.day(2), durationSeconds: 400),
        ]
        let stats = StatsAggregator.compute(
            sessions: sessions, books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.streakDays == 2)
    }

    @Test func streakSumsMultipleSessionsPerDay() {
        // 200 + 200 today crosses the 300s threshold even though each
        // individual session is below it.
        let sessions = [
            Self.session(endedAt: Self.day(0, secondsIntoDay: 10 * 3600), durationSeconds: 200),
            Self.session(endedAt: Self.day(0, secondsIntoDay: 14 * 3600), durationSeconds: 200),
        ]
        let stats = StatsAggregator.compute(
            sessions: sessions, books: [],
            now: Self.now, calendar: Self.utcCalendar
        )
        #expect(stats.streakDays == 1)
    }

    // MARK: continueReadingCandidate()

    @Test func candidateNilWhenNoEligibleBooks() {
        let result = StatsAggregator.continueReadingCandidate(
            books: [], progressByBookID: [:], sessions: []
        )
        #expect(result == nil)
    }

    @Test func candidateFiltersOutFinishedAndArchivedAndUndownloaded() {
        let downloaded = Self.book(filename: "ok.epub")
        let undownloaded = Self.book(filename: nil)
        let archived = Self.book(archived: true)
        let finished = Self.book(finishedAt: Self.now)
        let result = StatsAggregator.continueReadingCandidate(
            books: [undownloaded, archived, finished, downloaded],
            progressByBookID: [
                downloaded.id: 0.4,
                undownloaded.id: 0.4,
                archived.id: 0.4,
                finished.id: 0.4,
            ],
            sessions: []
        )
        #expect(result?.id == downloaded.id)
    }

    /// Verifies that books with `progress >= 0.95` are filtered out.
    /// The other two books (progress 0.0 and 0.4) are BOTH eligible —
    /// progress 0 is allowed by spec for fresh downloads. `mid` wins
    /// the tie-break (later in input order; see `continueReadingCandidate`
    /// for the explicit `enumerated()`-based tie-breaker).
    @Test func candidateFiltersOutOver95Progress() {
        let zero = Self.book()
        let over = Self.book()
        let mid = Self.book()
        let result = StatsAggregator.continueReadingCandidate(
            books: [zero, over, mid],
            progressByBookID: [
                zero.id: 0.0,
                over.id: 0.96,
                mid.id: 0.4,
            ],
            sessions: []
        )
        #expect(result?.id == mid.id)
    }

    @Test func candidateSortsByMostRecentSession() {
        let older = Self.book()
        let newer = Self.book()
        let result = StatsAggregator.continueReadingCandidate(
            books: [older, newer],
            progressByBookID: [older.id: 0.3, newer.id: 0.3],
            sessions: [
                Self.session(bookID: older.id, endedAt: Self.day(5), durationSeconds: 100),
                Self.session(bookID: newer.id, endedAt: Self.day(1), durationSeconds: 100),
            ]
        )
        #expect(result?.id == newer.id)
    }

    @Test func candidateFallsBackToAddedAtWhenNoSessions() {
        let older = Self.book(addedAt: Date(timeIntervalSince1970: 1_000))
        let newer = Self.book(addedAt: Date(timeIntervalSince1970: 2_000))
        let result = StatsAggregator.continueReadingCandidate(
            books: [older, newer],
            progressByBookID: [older.id: 0.3, newer.id: 0.3],
            sessions: []
        )
        #expect(result?.id == newer.id)
    }

    @Test func candidateFreshDownloadIncludedWhenProgressZero() {
        // The spec calls out fresh downloads as appearing in the hero.
        // Eligibility allows progress == 0 for the "never opened yet" case.
        let fresh = Self.book(addedAt: Self.day(1))
        let result = StatsAggregator.continueReadingCandidate(
            books: [fresh],
            progressByBookID: [:],          // no progress row yet
            sessions: []
        )
        #expect(result?.id == fresh.id)
    }
}

@MainActor
@Suite("StatsAggregator.paceEstimate")
struct PaceEstimateTests {

    private static func makeBook(furthestLinearPosition: Int, totalPositions: Int) -> Book {
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: nil
        )
        book.furthestLinearPosition = furthestLinearPosition
        book.totalPositions = totalPositions
        return book
    }

    private func makeSession(
        bookID: UUID,
        durationSeconds: Int,
        pagesAdded: Int,
        endedAt: Date = Date()
    ) -> ReadingSession {
        ReadingSession(
            id: UUID(),
            bookID: bookID,
            startedAt: endedAt.addingTimeInterval(-TimeInterval(durationSeconds)),
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            pagesAdded: pagesAdded,
            endReason: "closed"
        )
    }

    @Test("returns nil when totalPositions == 0 (publication never opened)")
    func totalPositionsZero() {
        let book = Self.makeBook(furthestLinearPosition: 0, totalPositions: 0)
        let s = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 100)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.5, book: book, sessions: [s]
        )
        #expect(estimate == nil)
    }

    @Test("returns nil when per-book minutes < 5")
    func belowGate() {
        let book = Self.makeBook(furthestLinearPosition: 10, totalPositions: 100)
        let s = makeSession(bookID: book.id, durationSeconds: 4 * 60, pagesAdded: 10)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.10, book: book, sessions: [s]
        )
        #expect(estimate == nil)
    }

    @Test("returns medium confidence between 5 and 30 minutes")
    func mediumConfidence() {
        let book = Self.makeBook(furthestLinearPosition: 100, totalPositions: 1000)
        let s = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 100)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.10, book: book, sessions: [s]
        )
        #expect(estimate?.confidence == .medium)
    }

    @Test("returns high confidence at >=30 minutes")
    func highConfidence() {
        let book = Self.makeBook(furthestLinearPosition: 400, totalPositions: 1000)
        let s = makeSession(bookID: book.id, durationSeconds: 40 * 60, pagesAdded: 400)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.40, book: book, sessions: [s]
        )
        #expect(estimate?.confidence == .high)
    }

    @Test("clamps an extremely slow session to 60s/position ceiling")
    func clampsSlow() {
        let book = Self.makeBook(furthestLinearPosition: 1, totalPositions: 11)
        let s = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 1)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 1.0 / 11.0, book: book, sessions: [s]
        )
        #expect(estimate?.secondsRemaining == 600)
    }

    @Test("clamps an extremely fast session to 1.5s/position floor")
    func clampsFast() {
        let book = Self.makeBook(furthestLinearPosition: 10_000, totalPositions: 10_100)
        let s = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 10_000)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 10_000.0 / 10_100.0, book: book, sessions: [s]
        )
        #expect(estimate?.secondsRemaining == 150)
    }

    @Test("blends global with per-book between 5 and 30 minutes")
    func blends() {
        let book = Self.makeBook(furthestLinearPosition: 100, totalPositions: 150)
        let otherBookID = UUID()
        let perBook = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 100)
        let other = makeSession(bookID: otherBookID, durationSeconds: 50 * 60, pagesAdded: 200)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 100.0 / 150.0, book: book, sessions: [perBook, other]
        )
        guard let secs = estimate?.secondsRemaining else {
            Issue.record("expected non-nil estimate")
            return
        }
        #expect((535...545).contains(secs))
    }

    @Test("excludes pagesAdded==0 sessions from pace calc")
    func excludesUncreditedSessions() {
        let book = Self.makeBook(furthestLinearPosition: 100, totalPositions: 200)
        let real = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 100)
        let scrubOnly = makeSession(bookID: book.id, durationSeconds: 60 * 60, pagesAdded: 0)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.5, book: book, sessions: [real, scrubOnly]
        )
        guard let secs = estimate?.secondsRemaining else {
            Issue.record("expected non-nil estimate")
            return
        }
        #expect((595...605).contains(secs))
    }

    @Test("anchor uses max(furthestLinearPosition, cursorPosition)")
    func anchorUsesMax() {
        // cursor = Int(0.1 * 1000) = 100 < furthestLinearPosition = 500,
        // so anchor = 500, remaining = 500.
        // pace = clamp(600/500, 1.5, 60) = 1.5 → result = 750 ≈ 745...755.
        let book = Self.makeBook(furthestLinearPosition: 500, totalPositions: 1000)
        let s = makeSession(bookID: book.id, durationSeconds: 10 * 60, pagesAdded: 500)
        let estimate = StatsAggregator.paceEstimate(
            bookID: book.id, progressFraction: 0.1, book: book, sessions: [s]
        )
        guard let secs = estimate?.secondsRemaining else {
            Issue.record("expected non-nil estimate")
            return
        }
        #expect((745...755).contains(secs))
    }
}
