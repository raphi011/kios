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
        var minPosition: Int
        var maxPosition: Int
        var idleTimer: Task<Void, Never>?
    }

    private let context: ModelContext
    private let clock: StatsClock
    private let idleTimeoutSeconds: Int
    private let minSessionSeconds: Int = 5
    /// Gap cap applied to each (lastActivityAt → now) window.
    /// Must equal `idleTimeoutSeconds` for the math to line up.
    private var gapCapSeconds: Int { idleTimeoutSeconds }

    private var active: ActiveSession?

    init(
        context: ModelContext,
        clock: StatsClock = .real,
        idleTimeoutSeconds: Int = 120
    ) {
        self.context = context
        self.clock = clock
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    // MARK: - Lifecycle entry points

    func sessionDidOpen(bookID: UUID, initialPosition: Int, totalPositions: Int) {
        // If a session is already active for a different book, close it.
        if let existing = active, existing.bookID != bookID {
            close(reason: .closed)
        }
        let now = clock.now()
        active = ActiveSession(
            bookID: bookID,
            startedAt: now,
            lastActivityAt: now,
            accumulatedSeconds: 0,
            minPosition: initialPosition,
            maxPosition: initialPosition,
            idleTimer: nil
        )
        // Idle timer scheduled in Task 8.
    }

    func sessionDidAdvance(position: Int, totalPositions: Int, bookID: UUID? = nil) {
        let now = clock.now()
        if active == nil, let bookID {
            active = ActiveSession(
                bookID: bookID,
                startedAt: now,
                lastActivityAt: now,
                accumulatedSeconds: 0,
                minPosition: position,
                maxPosition: position,
                idleTimer: nil
            )
            return
        }
        guard var current = active else { return }
        let gap = min(Int(now.timeIntervalSince(current.lastActivityAt)), gapCapSeconds)
        current.accumulatedSeconds += max(gap, 0)
        current.lastActivityAt = now
        current.minPosition = min(current.minPosition, position)
        current.maxPosition = max(current.maxPosition, position)
        active = current
        // Idle timer reset scheduled in Task 8.
    }

    func sessionDidClose(reason: EndReason) {
        close(reason: reason)
    }

    // MARK: - Internals

    private func close(reason: EndReason) {
        guard var current = active else { return }
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
            minPosition: current.minPosition,
            maxPosition: current.maxPosition,
            pagesAdded: max(current.maxPosition - current.minPosition, 0),
            endReason: reason.rawValue
        )
        context.insert(session)
        try? context.save()
    }
}
