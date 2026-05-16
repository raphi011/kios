import Foundation
import SwiftData
import SwiftUI

/// Active reading session lifecycle + persistence. One instance per app,
/// owned by `AppEnvironment`. Main-actor isolated; safe to call from
/// SwiftUI lifecycle handlers (`.onAppear`, `.onDisappear`,
/// `.onChange(of: scenePhase)`).
///
/// State machine:
///   - `nil` active session → `sessionDidOpen` or `sessionDidAdvance` starts one.
///   - active session → `sessionDidAdvance` updates; `sessionDidClose` persists.
///   - idle timer fires → `sessionDidClose(.idle)` (see Task 8).
@MainActor
@Observable
final class ReadingStatsService {
    enum EndReason: String {
        case closed
        case backgrounded
        case idle
        case locked
    }

    /// In-memory state for the active reading session.
    private struct ActiveSession {
        let bookID: UUID
        let startedAt: Date
        var lastActivityAt: Date
        var accumulatedSeconds: Int
        var pagesAdded: Int
        var lastSeenLinearPosition: Int
        var idleTimer: Task<Void, Never>?
    }

    private let context: ModelContext
    private let clock: StatsClock
    private let idleTimeoutSeconds: Int
    /// Sessions shorter than this are dropped on close — protects against
    /// noise from accidental reader opens. Production default is 5s; tests
    /// inject lower values to isolate the lifecycle path from the floor.
    private let minSessionSeconds: Int
    /// Gap cap applied to each (lastActivityAt → now) window.
    /// Must equal `idleTimeoutSeconds` for the math to line up.
    private var gapCapSeconds: Int { idleTimeoutSeconds }
    /// Maximum forward delta (in positions) that qualifies as a linear page
    /// turn. Larger jumps are treated as navigation even when source is .swipe.
    private let linearAdvanceThreshold = 5

    private var active: ActiveSession?

    /// Set by `sessionDidAdvance` on navigation sources. Cleared by user
    /// action, the next linear advance, the next nav-jump (replacement),
    /// or session close. Drives `JumpRecoveryPill`.
    var pendingJumpReturn: JumpReturnTarget?

    struct JumpReturnTarget: Equatable {
        /// 0-indexed Readium position to return to.
        let fromPosition: Int
        /// 0-indexed Readium position the user jumped to.
        let toPosition: Int
    }

    init(
        context: ModelContext,
        clock: StatsClock = .real,
        idleTimeoutSeconds: Int = 120,
        minSessionSeconds: Int = 5
    ) {
        self.context = context
        self.clock = clock
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.minSessionSeconds = minSessionSeconds
    }

    // MARK: - Lifecycle entry points

    func sessionDidOpen(bookID: UUID, initialPosition: Int, totalPositions: Int) {
        if let existing = active, existing.bookID != bookID {
            close(reason: .closed)
        }
        let now = clock.now()
        active = ActiveSession(
            bookID: bookID,
            startedAt: now,
            lastActivityAt: now,
            accumulatedSeconds: 0,
            pagesAdded: 0,
            lastSeenLinearPosition: initialPosition,
            idleTimer: nil
        )
        scheduleIdleTimer()
        bumpWatermarkOnResume(bookID: bookID, position: initialPosition)
    }

    private func bumpWatermarkOnResume(bookID: UUID, position: Int) {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        guard let book = try? context.fetch(descriptor).first else { return }
        if position > book.furthestLinearPosition {
            book.furthestLinearPosition = position
            try? context.save()
        }
    }

    func sessionDidAdvance(
        position: Int,
        totalPositions: Int,
        source: AdvanceSource,
        bookID: UUID? = nil
    ) {
        // .programmaticReturn is a navigation-control artifact, not a stat event.
        if source == .programmaticReturn { return }

        let now = clock.now()

        // Auto-start a session if none exists (matches v1 behaviour).
        if active == nil, let bookID {
            active = ActiveSession(
                bookID: bookID,
                startedAt: now,
                lastActivityAt: now,
                accumulatedSeconds: 0,
                pagesAdded: 0,
                lastSeenLinearPosition: position,
                idleTimer: nil
            )
            scheduleIdleTimer()
        }

        guard var current = active else { return }

        // Time accumulation — unchanged from v1: gap-capped to idleTimeoutSeconds.
        let gap = min(Int(now.timeIntervalSince(current.lastActivityAt)), gapCapSeconds)
        current.accumulatedSeconds += max(gap, 0)
        current.lastActivityAt = now

        let effectiveBookID = bookID ?? current.bookID
        let book = fetchBook(id: effectiveBookID)
        let oldFurthest = book?.furthestLinearPosition ?? 0

        // Time accumulation runs before this branch intentionally: the gap
        // since lastActivityAt is real reading time on another device or in
        // a prior session window. gapCapSeconds bounds runaway accumulation.
        if source.bumpsWatermarkOnResume {
            if let book, position > oldFurthest {
                book.furthestLinearPosition = position
                try? context.save()
            }
            active = current
            scheduleIdleTimer()
            return
        }

        if source.isLinear {
            // Implicit "Stay here" if the recovery pill was up.
            pendingJumpReturn = nil

            if let book,
               position > oldFurthest,
               (position - oldFurthest) <= linearAdvanceThreshold {
                let delta = position - oldFurthest
                book.furthestLinearPosition = position
                current.pagesAdded += delta
                try? context.save()
                applyAutoFinish(book: book, totalPositions: totalPositions)
            }
            current.lastSeenLinearPosition = position
        }

        if source.triggersJumpPill {
            pendingJumpReturn = JumpReturnTarget(
                fromPosition: current.lastSeenLinearPosition,
                toPosition: position
            )
        }

        active = current
        scheduleIdleTimer()
    }

    private func fetchBook(id: UUID) -> Book? {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func sessionDidClose(reason: EndReason) {
        close(reason: reason)
    }

    // MARK: - Internals

    private func scheduleIdleTimer() {
        active?.idleTimer?.cancel()
        let bookID = active?.bookID
        let clock = self.clock
        let timeout = self.idleTimeoutSeconds
        let timer = Task { [weak self] in
            do {
                try await clock.sleep(timeout)
            } catch {
                return  // cancelled — normal path on every advance.
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Only fire if we're still in the same active session.
                guard self.active?.bookID == bookID else { return }
                self.close(reason: .idle)
            }
        }
        active?.idleTimer = timer
    }

    private func applyAutoFinish(book: Book, totalPositions: Int) {
        guard totalPositions > 0,
              book.finishedAt == nil,
              !book.finishedManually else { return }
        let progression = Double(book.furthestLinearPosition) / Double(totalPositions)
        if progression >= 0.95 {
            book.finishedAt = clock.now()
            try? context.save()
        }
    }

    private func close(reason: EndReason) {
        guard let current = active else { return }
        defer { active = nil }
        current.idleTimer?.cancel()

        let now = clock.now()
        let finalGap = min(Int(now.timeIntervalSince(current.lastActivityAt)), gapCapSeconds)
        let duration = current.accumulatedSeconds + max(finalGap, 0)

        guard duration >= minSessionSeconds else { return }

        let session = ReadingSession(
            id: UUID(),
            bookID: current.bookID,
            startedAt: current.startedAt,
            endedAt: now,
            durationSeconds: duration,
            pagesAdded: current.pagesAdded,
            endReason: reason.rawValue
        )
        context.insert(session)
        try? context.save()
    }
}
