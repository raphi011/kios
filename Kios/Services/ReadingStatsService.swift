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
    /// Sessions shorter than this are dropped on close — protects against
    /// noise from accidental reader opens. Production default is 5s; tests
    /// inject lower values to isolate the lifecycle path from the floor.
    private let minSessionSeconds: Int
    /// Gap cap applied to each (lastActivityAt → now) window.
    /// Must equal `idleTimeoutSeconds` for the math to line up.
    private var gapCapSeconds: Int { idleTimeoutSeconds }

    private var active: ActiveSession?

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
        scheduleIdleTimer()
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
            scheduleIdleTimer()
            applyAutoFinish(bookID: active?.bookID, position: position, totalPositions: totalPositions)
            return
        }
        guard var current = active else { return }
        let gap = min(Int(now.timeIntervalSince(current.lastActivityAt)), gapCapSeconds)
        current.accumulatedSeconds += max(gap, 0)
        current.lastActivityAt = now
        current.minPosition = min(current.minPosition, position)
        current.maxPosition = max(current.maxPosition, position)
        active = current
        scheduleIdleTimer()
        applyAutoFinish(bookID: active?.bookID, position: position, totalPositions: totalPositions)
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

    private func applyAutoFinish(bookID: UUID?, position: Int, totalPositions: Int) {
        guard let bookID, totalPositions > 0 else { return }
        let progression = Double(position) / Double(totalPositions)
        guard progression >= 0.95 else { return }

        let descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.id == bookID }
        )
        guard let book = try? context.fetch(descriptor).first else { return }
        guard book.finishedAt == nil, !book.finishedManually else { return }
        book.finishedAt = clock.now()
        try? context.save()
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
            minPosition: current.minPosition,
            maxPosition: current.maxPosition,
            pagesAdded: max(current.maxPosition - current.minPosition, 0),
            endReason: reason.rawValue
        )
        context.insert(session)
        try? context.save()
    }
}
