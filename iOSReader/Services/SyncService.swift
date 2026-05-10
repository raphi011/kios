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

    /// Persists local progress AND attempts to push to server. On network
    /// failure, the local row is marked `pendingUpload = true` so a future
    /// retry can resend.
    func push(
        book: Book,
        locatorJSON: String,
        chapter: Int,
        intraProgression: Double,
        percentage: Double
    ) async {
        guard let hash = book.partialMD5 else { return }
        let progressString = ProgressMapper.encodeProgress(
            chapter: chapter, intraProgression: intraProgression
        )
        upsertLocal(
            bookID: book.id,
            locatorJSON: locatorJSON,
            percentage: percentage,
            pendingUpload: true
        )
        do {
            try await kosync.putProgress(.init(
                document: hash,
                progress: progressString,
                percentage: percentage,
                device: deviceName,
                deviceID: deviceID
            ))
            upsertLocal(
                bookID: book.id,
                locatorJSON: locatorJSON,
                percentage: percentage,
                pendingUpload: false
            )
        } catch {
            // Leave pendingUpload = true; foreground retry will resend.
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
        if let existing = currentLocalProgress(for: bookID) {
            existing.locatorJSON = locatorJSON
            existing.percentage = percentage
            existing.updatedAt = .now
            existing.deviceID = deviceID
            existing.pendingUpload = pendingUpload
        } else {
            context.insert(ReadingProgress(
                bookID: bookID,
                locatorJSON: locatorJSON,
                percentage: percentage,
                updatedAt: .now,
                deviceID: deviceID,
                pendingUpload: pendingUpload
            ))
        }
        try? context.save()
    }
}
