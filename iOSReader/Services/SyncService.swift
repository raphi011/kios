import Foundation
import SwiftData
import Core

@MainActor
final class SyncService {
    /// Closure (not stored backend) so the factory output can change across
    /// protocol switches without re-creating `SyncService`. Throwing so a
    /// missing-credentials build failure at flush time falls through to the
    /// same error-swallowing path as a network failure (row stays pending,
    /// next trigger retries).
    private let backendForProtocol: @MainActor (SyncProtocol) throws -> any SyncBackend
    private let context: ModelContext
    let activeProtocol: SyncProtocol
    let deviceID: String
    let deviceName: String

    /// Threshold for prompting when server progress is from a different
    /// device. Spec §4.7 notes this is tunable; >1% chosen to ignore noise
    /// from rounding while still catching cross-device reads.
    private static let promptThreshold: Double = 0.01

    init(
        backendForProtocol: @escaping @MainActor (SyncProtocol) throws -> any SyncBackend,
        context: ModelContext,
        activeProtocol: SyncProtocol,
        deviceID: String,
        deviceName: String
    ) {
        self.backendForProtocol = backendForProtocol
        self.context = context
        self.activeProtocol = activeProtocol
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// What the UI should do when the user opens a book.
    enum OnOpenAction: Equatable {
        case useLocal
        case applyServer(progress: CanonicalProgress)
        case promptUser(local: Double, server: CanonicalProgress)
    }

    /// Decide based on local + server progress. Server progress is fetched
    /// via the active protocol's backend. Returns `.useLocal` if there's no
    /// server record, or if server progress is from this device (i.e., we
    /// wrote it).
    func onOpen(book: Book) async throws -> OnOpenAction {
        let backend = try backendForProtocol(activeProtocol)
        guard let server = try await backend.fetchProgress(for: book.identity) else {
            return .useLocal
        }
        let local = currentLocalProgress(for: book.id)
        if server.deviceID == deviceID { return .useLocal }

        let localPercentage = local?.percentage ?? 0
        let delta = server.percentage - localPercentage

        if delta > Self.promptThreshold {
            return .promptUser(local: localPercentage, server: server)
        }
        if server.percentage > localPercentage {
            return .applyServer(progress: server)
        }
        return .useLocal
    }

    /// Local-only: upsert `ReadingProgress` with `pendingUpload = true` and
    /// `pendingProtocol = activeProtocol`. Cheap; called on every page turn.
    /// Protocol-specific encoding (kosync progress string, kobo location)
    /// is handled by the backend at flush time, not here.
    func bufferLocator(
        book: Book,
        locatorJSON: String,
        percentage: Double
    ) {
        upsertLocal(
            bookID: book.id,
            locatorJSON: locatorJSON,
            percentage: percentage,
            pendingUpload: true
        )
    }

    /// Network: if the `ReadingProgress` row for `book` has
    /// `pendingUpload == true`, push to the backend pinned by
    /// `row.pendingProtocol`. NOT the active protocol — pinning ensures a
    /// user switching protocols mid-buffer still flushes the buffered write
    /// via the originally-targeted backend.
    func flushPendingProgress(for book: Book) async {
        guard let row = currentLocalProgress(for: book.id),
              row.pendingUpload,
              let pinned = row.pendingProtocol,
              let proto = SyncProtocol(rawValue: pinned) else { return }
        do {
            let backend = try backendForProtocol(proto)
            // The model's `canonical` carries `deviceName: ""` because it
            // doesn't know the service's identity. Fill it in here so the
            // backend can attach a meaningful device tag on the wire.
            let rowCanonical = row.canonical
            let canonical = CanonicalProgress(
                percentage: rowCanonical.percentage,
                locatorJSON: rowCanonical.locatorJSON,
                timestamp: rowCanonical.timestamp,
                deviceID: rowCanonical.deviceID,
                deviceName: deviceName
            )
            try await backend.pushProgress(canonical, for: book.identity)
            row.pendingUpload = false
            row.pendingProtocol = nil
            try? context.save()
        } catch {
            // Leave pendingUpload = true and pendingProtocol pinned;
            // next trigger retries via the SAME backend.
        }
    }

    /// Foreground retry: flush any pending rows across all books. Called from
    /// the app's scenePhase = .active transition.
    func flushAllPending() async {
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.pendingUpload == true }
        )
        guard let rows = try? context.fetch(descriptor) else { return }
        for row in rows {
            let bookID = row.bookID
            let bookDescriptor = FetchDescriptor<Book>(
                predicate: #Predicate { $0.id == bookID }
            )
            guard let book = try? context.fetch(bookDescriptor).first else { continue }
            await flushPendingProgress(for: book)
        }
    }

    // MARK: - private

    private func currentLocalProgress(for bookID: UUID) -> ReadingProgress? {
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return try? context.fetch(descriptor).first
    }

    private func upsertLocal(
        bookID: UUID,
        locatorJSON: String,
        percentage: Double,
        pendingUpload: Bool
    ) {
        // Pin the protocol at buffer time so a mid-flush user-driven protocol
        // switch still flushes the buffered write via the originally-targeted
        // backend.
        let pendingProtocol: String? = pendingUpload ? activeProtocol.rawValue : nil
        if let existing = currentLocalProgress(for: bookID) {
            existing.locatorJSON = locatorJSON
            existing.percentage = percentage
            existing.updatedAt = .now
            existing.deviceID = deviceID
            existing.pendingUpload = pendingUpload
            existing.pendingProtocol = pendingProtocol
            // Don't touch koSyncProgressString / koboLocationSource /
            // koboLocationValue here — those are server-side state caches
            // populated by onOpen / push results.
        } else {
            context.insert(ReadingProgress(
                bookID: bookID,
                locatorJSON: locatorJSON,
                koSyncProgressString: nil,
                koboLocationSource: nil,
                koboLocationValue: nil,
                percentage: percentage,
                updatedAt: .now,
                deviceID: deviceID,
                pendingUpload: pendingUpload,
                pendingProtocol: pendingProtocol
            ))
        }
        try? context.save()
    }
}
