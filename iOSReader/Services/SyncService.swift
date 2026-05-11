import Foundation
import SwiftData
import Core

@MainActor
final class SyncService {
    private let kosync: KOSyncClient
    private let context: ModelContext
    let deviceID: String
    let deviceName: String

    /// Threshold for prompting when server progress is from a different
    /// device. Spec §4.7 notes this is tunable; >1% chosen to ignore noise
    /// from rounding while still catching cross-device reads.
    private static let promptThreshold: Double = 0.01

    init(
        kosync: KOSyncClient,
        context: ModelContext,
        deviceID: String,
        deviceName: String
    ) {
        self.kosync = kosync
        self.context = context
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// What the UI should do when the user opens a book.
    enum OnOpenAction: Equatable {
        case useLocal
        case applyServer(progress: ProgressDownload)
        case promptUser(local: Double, server: ProgressDownload)
    }

    /// Decide based on local + server progress. Server progress is fetched
    /// via kosync. Returns `.useLocal` if there's no server record, or if
    /// server progress is from this device (i.e., we wrote it).
    func onOpen(book: Book) async throws -> OnOpenAction {
        guard let hash = book.partialMD5 else { return .useLocal }
        guard let server = try await kosync.getProgress(documentHash: hash) else {
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

    /// Local-only: upsert ReadingProgress with pendingUpload = true. Cheap;
    /// called on every page turn so Home always shows current progress and the
    /// file system survives an app crash.
    func bufferLocator(
        book: Book,
        locatorJSON: String,
        chapter: Int,
        intraProgression: Double,
        percentage: Double
    ) {
        let progressString = KOSyncProgressMapper.encodeProgress(
            chapter: chapter, intraProgression: intraProgression
        )
        upsertLocal(
            bookID: book.id,
            locatorJSON: locatorJSON,
            koSyncProgressString: progressString,
            percentage: percentage,
            pendingUpload: true
        )
    }

    /// Network: if the ReadingProgress row for `book` has pendingUpload == true,
    /// PUT the stored values to kosync. On success flips the flag. On failure
    /// leaves the flag for the next trigger.
    func flushPendingProgress(for book: Book) async {
        guard let hash = book.partialMD5,
              let row = currentLocalProgress(for: book.id),
              row.pendingUpload,
              let progressString = row.koSyncProgressString else { return }
        do {
            try await kosync.putProgress(.init(
                document: hash,
                progress: progressString,
                percentage: row.percentage,
                device: deviceName,
                deviceID: deviceID
            ))
            row.pendingUpload = false
            row.pendingProtocol = nil
            try? context.save()
        } catch {
            // Leave pendingUpload = true; next trigger retries.
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
        koSyncProgressString: String,
        percentage: Double,
        pendingUpload: Bool
    ) {
        // Pin the protocol at buffer time so a mid-flush user-driven protocol
        // switch still flushes the buffered write via the originally-targeted
        // backend.
        let pendingProtocol: String? = pendingUpload ? "kosync" : nil
        if let existing = currentLocalProgress(for: bookID) {
            existing.locatorJSON = locatorJSON
            existing.koSyncProgressString = koSyncProgressString
            existing.percentage = percentage
            existing.updatedAt = .now
            existing.deviceID = deviceID
            existing.pendingUpload = pendingUpload
            existing.pendingProtocol = pendingProtocol
        } else {
            context.insert(ReadingProgress(
                bookID: bookID,
                locatorJSON: locatorJSON,
                koSyncProgressString: koSyncProgressString,
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
