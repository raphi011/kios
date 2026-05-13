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
        env.service.sessionDidAdvance(position: 11, totalPositions: 100)
        env.clock.advance(by: 50)
        env.service.sessionDidAdvance(position: 13, totalPositions: 100)
        env.clock.advance(by: 10)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.bookID == env.book.id)
        #expect(s.endReason == "closed")
        #expect(s.minPosition == 10)
        #expect(s.maxPosition == 13)
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
        env.service.sessionDidAdvance(position: 1, totalPositions: 100)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        // 500-sec gap capped to 120, plus a 0-sec final gap.
        #expect(sessions[0].durationSeconds == 120)
    }

    @Test func sessionDidAdvanceAutoStartsNewSessionIfNoneActive() throws {
        let env = try Self.makeEnv()

        // No `sessionDidOpen` first — advance with explicit bookID should start a session.
        env.service.sessionDidAdvance(position: 10, totalPositions: 100, bookID: env.book.id)
        env.clock.advance(by: 30)
        env.service.sessionDidAdvance(position: 12, totalPositions: 100, bookID: env.book.id)
        env.clock.advance(by: 5)
        env.service.sessionDidClose(reason: .closed)

        let sessions = try env.context.fetch(FetchDescriptor<ReadingSession>())
        #expect(sessions.count == 1)
        #expect(sessions[0].pagesAdded == 2)
        // Only the gap between the two advances is counted; the implicit
        // open at position 10 carries lastActivityAt=now, so first gap = 30.
        #expect(sessions[0].durationSeconds == 35)
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
