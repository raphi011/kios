import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("ReadingStatsService (basics)", .serialized)
struct ReadingStatsServiceBasicTests {

    /// Mutable wall clock used by the service in tests. Advanced manually.
    /// Sleep is deliberately indefinite so the idle timer never fires during
    /// these basic tests — cancellation (triggered by scheduleIdleTimer on
    /// every advance/close) throws out of `Task.sleep` cleanly.
    ///
    /// `@unchecked Sendable`: test-only helper. The single-threaded test
    /// runner serializes access to `current`; there's no real race here.
    final class TestClock: @unchecked Sendable {
        var current: Date
        init(start: Date) { self.current = start }
        func advance(by seconds: Int) { current = current.addingTimeInterval(TimeInterval(seconds)) }
        func statsClock() -> StatsClock {
            StatsClock(
                now: { [self] in self.current },
                sleep: { _ in
                    // Effectively forever; cancellation by the service throws
                    // a `CancellationError` which the timer Task catches.
                    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
                }
            )
        }
    }

    private static func makeEnv() throws -> (
        service: ReadingStatsService,
        context: ModelContext,
        book: Book,
        clock: TestClock
    ) {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: "x.epub"
        )
        context.insert(book)
        try context.save()

        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let service = ReadingStatsService(
            context: context,
            clock: clock.statsClock(),
            idleTimeoutSeconds: 120
        )
        return (service, context, book, clock)
    }

    @Test func openAdvanceAdvanceClosePersistsOneSession() throws {
        let env = try Self.makeEnv()

        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 10, totalPositions: 100)
        env.clock.advance(by: 30)
        env.service.sessionDidAdvance(position: 11, totalPositions: 100, source: .swipe)
        env.clock.advance(by: 50)
        env.service.sessionDidAdvance(position: 13, totalPositions: 100, source: .swipe)
        env.clock.advance(by: 10)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.bookID == env.book.id)
        #expect(s.endReason == "closed")
        #expect(s.pagesAdded == 3)
        // 30 + 50 + 10 = 90s of active time (all gaps under 120).
        #expect(s.durationSeconds == 90)
    }

    @Test func openAndImmediateCloseBelowFloorDropsSession() throws {
        let env = try Self.makeEnv()

        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 2)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 0)
    }

    @Test func gapsLongerThan120SecondsAreCapped() throws {
        let env = try Self.makeEnv()

        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 100)
        env.clock.advance(by: 500)  // user "fell asleep" — but no idle timer
                                    // fired because tests use an indefinite sleep.
                                    // The cap should still kick in.
        env.service.sessionDidAdvance(position: 1, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        // 500-sec gap capped to 120, plus a 0-sec final gap.
        #expect(sessions[0].durationSeconds == 120)
    }

    @Test func openAtPositionAboveWatermarkBumpsIt() throws {
        let env = try Self.makeEnv()
        #expect(env.book.furthestLinearPosition == 0)
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 30, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.furthestLinearPosition == 30)
    }

    @Test func openAtPositionBelowWatermarkDoesNotMoveIt() throws {
        let env = try Self.makeEnv()
        env.book.furthestLinearPosition = 50
        try env.context.save()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 10, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.furthestLinearPosition == 50)
    }

    @Test func sessionDidAdvanceAutoStartsNewSessionIfNoneActive() throws {
        let env = try Self.makeEnv()
        // Seed watermark at 10 so the first advance (position 10) is not
        // above the watermark and earns no credit; only the second advance
        // (position 12, delta 2 from watermark 10) earns the 2 pages.
        env.book.furthestLinearPosition = 10
        try env.context.save()

        // No `sessionDidOpen` first — advance with explicit bookID should start a session.
        env.service.sessionDidAdvance(position: 10, totalPositions: 100, source: .swipe, bookID: env.book.id)
        env.clock.advance(by: 30)
        env.service.sessionDidAdvance(position: 12, totalPositions: 100, source: .swipe, bookID: env.book.id)
        env.clock.advance(by: 5)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].pagesAdded == 2)
        // Only the gap between the two advances is counted; the implicit
        // open at position 10 carries lastActivityAt=now, so first gap = 30.
        #expect(sessions[0].durationSeconds == 35)
    }

    @Test func openAtPositionEqualToWatermarkDoesNotMoveIt() throws {
        let env = try Self.makeEnv()
        env.book.furthestLinearPosition = 25
        try env.context.save()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 25, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.furthestLinearPosition == 25)
    }
}

@MainActor
@Suite("ReadingStatsService idle timer", .serialized)
struct ReadingStatsServiceIdleTests {

    /// This suite uses a real (short) idle timeout instead of a gated mock
    /// clock — `StatsClock` is `Sendable` and resists being mocked across
    /// the timer's background Task boundary, while a 1-sec real timeout is
    /// fast enough that the test runtime stays manageable. The 5-second
    /// minimum-session floor is bypassed via `minSessionSeconds: 0` so the
    /// test isolates the idle path.
    @Test func idleFireEndsSessionWithIdleReason() async throws {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: "x.epub"
        )
        context.insert(book)
        try context.save()

        let service = ReadingStatsService(
            context: context,
            clock: .real,
            idleTimeoutSeconds: 1,
            minSessionSeconds: 0
        )
        service.sessionDidOpen(bookID: book.id, initialPosition: 0, totalPositions: 100)

        // Wait past the idle timeout + a buffer for the timer Task to
        // hop back onto MainActor and persist.
        try await Task.sleep(for: .milliseconds(1500))

        let sessions = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].endReason == "idle")
        // Active time ≈ 1 sec (the idle timeout). Allow ±1 sec slack to
        // absorb scheduling jitter.
        #expect(sessions[0].durationSeconds >= 1 && sessions[0].durationSeconds <= 2)
    }
}

@MainActor
@Suite("ReadingStatsService auto-finish", .serialized)
struct ReadingStatsServiceAutoFinishTests {

    /// See `ReadingStatsServiceBasicTests.TestClock` for the @unchecked rationale.
    final class FixedClock: @unchecked Sendable {
        var current: Date
        init(start: Date) { self.current = start }
        func advance(by seconds: Int) { current = current.addingTimeInterval(TimeInterval(seconds)) }
        func statsClock() -> StatsClock {
            StatsClock(
                now: { [self] in self.current },
                // Indefinite sleep — idle timer never fires here. Same
                // reason as in `ReadingStatsServiceBasicTests.TestClock`.
                sleep: { _ in
                    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
                }
            )
        }
    }

    private static func makeEnv(
        finishedAt: Date? = nil,
        finishedManually: Bool = false
    ) throws -> (service: ReadingStatsService, context: ModelContext, book: Book, clock: FixedClock) {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: "x.epub", finishedAt: finishedAt, finishedManually: finishedManually
        )
        context.insert(book)
        try context.save()

        let clock = FixedClock(start: Date(timeIntervalSince1970: 1_000_000))
        let service = ReadingStatsService(
            context: context, clock: clock.statsClock(), idleTimeoutSeconds: 120
        )
        return (service, context, book, clock)
    }

    @Test func advancingPast95SetsFinishedAt() throws {
        let env = try Self.makeEnv()
        env.book.furthestLinearPosition = 94
        try env.context.save()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 94, totalPositions: 100)
        env.clock.advance(by: 10)
        env.service.sessionDidAdvance(position: 95, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.finishedAt != nil)
    }

    @Test func advancingPast95DoesNotSetWhenAlreadyFinished() throws {
        let env = try Self.makeEnv()
        env.book.furthestLinearPosition = 94
        let originalFinishDate = Date(timeIntervalSince1970: 500_000)
        env.book.finishedAt = originalFinishDate
        try env.context.save()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 94, totalPositions: 100)
        env.clock.advance(by: 10)
        env.service.sessionDidAdvance(position: 95, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.finishedAt == originalFinishDate)  // unchanged
    }

    @Test func advancingPast95DoesNotSetWhenManuallyOverridden() throws {
        // User explicitly un-finished the book (finishedAt nil, finishedManually true).
        let env = try Self.makeEnv()
        env.book.furthestLinearPosition = 94
        env.book.finishedManually = true
        try env.context.save()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 94, totalPositions: 100)
        env.clock.advance(by: 10)
        env.service.sessionDidAdvance(position: 95, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.finishedAt == nil)  // manual override holds
    }

    @Test func advancingBelow95DoesNotSetFinishedAt() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 100)
        env.clock.advance(by: 30)
        env.service.sessionDidAdvance(position: 50, totalPositions: 100, source: .swipe)

        #expect(env.book.finishedAt == nil)
    }
}

@MainActor
@Suite("ReadingStatsService (watermark)", .serialized)
struct ReadingStatsServiceWatermarkTests {
    typealias TestClock = ReadingStatsServiceBasicTests.TestClock

    private static func makeEnv() throws -> (
        service: ReadingStatsService,
        context: ModelContext,
        book: Book,
        clock: TestClock
    ) {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: "x.epub"
        )
        context.insert(book)
        try context.save()
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let service = ReadingStatsService(
            context: context,
            clock: clock.statsClock(),
            idleTimeoutSeconds: 120
        )
        return (service, context, book, clock)
    }

    @Test("3 linear swipes from open at 0 credit 3 pages and bump watermark to 3")
    func threeLinearSwipes() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 1, totalPositions: 100, source: .swipe)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 2, totalPositions: 100, source: .swipe)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 3, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 3)
        #expect(env.book.furthestLinearPosition == 3)
    }

    @Test("scrub-commit does not credit, does not bump watermark")
    func scrubCommitNoCredit() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 10)
        env.service.sessionDidAdvance(position: 200, totalPositions: 1000, source: .scrubCommit)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 0)
        #expect(env.book.furthestLinearPosition == 5)
    }

    @Test("swipe after a scrub-jump is blocked by delta-from-furthest threshold")
    func swipeAfterScrubBlocked() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 1000)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 200, totalPositions: 1000, source: .scrubCommit)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 201, totalPositions: 1000, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 0)
        #expect(env.book.furthestLinearPosition == 5)
    }

    @Test("backward swipe (re-read) does not move watermark")
    func backwardSwipe() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 10, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 11, totalPositions: 100, source: .swipe)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 9, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 1)
        #expect(env.book.furthestLinearPosition == 11)
    }

    @Test("resumeFromSync bumps watermark but doesn't credit pages")
    func resumeFromSyncBumps() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 50, totalPositions: 100, source: .resumeFromSync)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 0)
        #expect(env.book.furthestLinearPosition == 50)
    }

    @Test("delta exceeding linearAdvanceThreshold is not credited")
    func deltaTooLarge() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 10, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 0)
        #expect(env.book.furthestLinearPosition == 0)
    }

    @Test("programmaticReturn is a no-op for stats")
    func programmaticReturnNoOp() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 200, totalPositions: 1000, source: .scrubCommit)
        env.service.sessionDidAdvance(position: 5, totalPositions: 1000, source: .programmaticReturn)
        env.service.sessionDidClose(reason: .closed)
        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.first?.pagesAdded == 0)
        #expect(env.book.furthestLinearPosition == 5)
    }

    @Test("watermark crossing 95% via linear swipes auto-finishes the book")
    func autoFinishOnLinearArrival() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 94, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 95, totalPositions: 100, source: .swipe)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.finishedAt != nil)
    }

    @Test("scrub-to-99% does not auto-finish")
    func scrubToEndDoesNotAutoFinish() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 99, totalPositions: 100, source: .scrubCommit)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.book.finishedAt == nil)
        #expect(env.book.furthestLinearPosition == 5)
    }

    @Test("dismissJumpPill clears pendingJumpReturn")
    func dismissPillStay() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 50, totalPositions: 100, source: .scrubCommit)
        #expect(env.service.pendingJumpReturn != nil)
        env.service.dismissJumpPill(commitStay: true)
        #expect(env.service.pendingJumpReturn == nil)
    }

    @Test("pill persists across linear swipes after a navigation jump")
    func pillPersistsAcrossSwipes() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 1000)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 500, totalPositions: 1000, source: .scrubCommit)
        #expect(env.service.pendingJumpReturn != nil)
        // Multiple linear swipes — pill stays sticky.
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 501, totalPositions: 1000, source: .swipe)
        #expect(env.service.pendingJumpReturn != nil)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 502, totalPositions: 1000, source: .swipe)
        #expect(env.service.pendingJumpReturn != nil)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 503, totalPositions: 1000, source: .tap)
        #expect(env.service.pendingJumpReturn != nil)
        // Original back-target is preserved.
        #expect(env.service.pendingJumpReturn?.fromPosition == 5)
    }

    @Test("a second nav jump replaces the existing pill target")
    func secondNavReplacesPill() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 1000)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 200, totalPositions: 1000, source: .scrubCommit)
        let firstTo = env.service.pendingJumpReturn?.toPosition
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 700, totalPositions: 1000, source: .tocJump)
        let secondTo = env.service.pendingJumpReturn?.toPosition
        #expect(firstTo == 200)
        #expect(secondTo == 700)
        #expect(env.service.pendingJumpReturn?.fromPosition == 5)
    }

    @Test("resumeFromSync updates lastSeenLinearPosition so next pill back-target is the resumed position")
    func resumeFromSyncUpdatesBackTarget() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 0, totalPositions: 1000)
        env.clock.advance(by: 5)
        // Sync-resume to position 300 mid-session (e.g., "Continue from another device" accepted).
        env.service.sessionDidAdvance(position: 300, totalPositions: 1000, source: .resumeFromSync)
        env.clock.advance(by: 5)
        // Now scrub-jump forward — pill back-target should be 300 (the resume), not 0.
        env.service.sessionDidAdvance(position: 700, totalPositions: 1000, source: .scrubCommit)
        #expect(env.service.pendingJumpReturn?.fromPosition == 300)
        #expect(env.service.pendingJumpReturn?.toPosition == 700)
    }

    @Test("close clears the pill")
    func closeClearsPill() throws {
        let env = try Self.makeEnv()
        env.service.sessionDidOpen(bookID: env.book.id, initialPosition: 5, totalPositions: 100)
        env.clock.advance(by: 5)
        env.service.sessionDidAdvance(position: 50, totalPositions: 100, source: .scrubCommit)
        env.service.sessionDidClose(reason: .closed)
        #expect(env.service.pendingJumpReturn == nil)
    }
}
