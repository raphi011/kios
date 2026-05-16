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
    private let spanResolver: (any KoboSpanResolving)?

    /// Threshold for prompting when server progress is from a different
    /// device. Spec §4.7 notes this is tunable; >1% chosen to ignore noise
    /// from rounding while still catching cross-device reads.
    private static let promptThreshold: Double = 0.01

    init(
        backendForProtocol: @escaping @MainActor (SyncProtocol) throws -> any SyncBackend,
        context: ModelContext,
        activeProtocol: SyncProtocol,
        deviceID: String,
        deviceName: String,
        spanResolver: (any KoboSpanResolving)? = nil
    ) {
        self.backendForProtocol = backendForProtocol
        self.context = context
        self.activeProtocol = activeProtocol
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.spanResolver = spanResolver
    }

    /// What the UI should do when the user opens a book.
    enum OnOpenAction: Equatable {
        case useLocal
        case applyServer(progress: CanonicalProgress)
        case promptUser(local: Double, server: CanonicalProgress)
    }

    /// Decide based on local + server progress. The comparison runs on
    /// timestamp + chapter + within-chapter progression. Whole-book percentage
    /// is the fallback when nothing better is parseable. This is necessary
    /// because real Kobo devices sometimes omit `ContentSourceProgressPercent`
    /// (whole-book) when they don't have a confident estimate — relying on
    /// percentage alone collapses every signal into one number and loses
    /// precision on cross-device handoffs.
    func onOpen(book: Book) async throws -> OnOpenAction {
        let backend = try backendForProtocol(activeProtocol)
        guard let server = try await backend.fetchProgress(for: book.identity) else {
            return .useLocal
        }
        let local = currentLocalProgress(for: book.id)
        // "I am the latest writer" shortcut. With a local row, we already
        // have this state on disk so the server fetch is redundant. Without
        // one (post-delete redownload, or fresh install on the same physical
        // device — `deviceID` is keychain-persisted), the server is the only
        // surviving copy of *our own* last position; silently restore it
        // rather than start over at 0%. No prompt — this isn't another
        // device's write, it's ours.
        if server.deviceID == deviceID {
            return local == nil ? .applyServer(progress: server) : .useLocal
        }

        let localPercentage = local?.percentage ?? 0
        let localTimestamp = local?.updatedAt ?? .distantPast

        // LWW gate. Same-or-older server is never authoritative, regardless
        // of what its chapter or percentage might suggest.
        if server.timestamp <= localTimestamp { return .useLocal }

        let serverLoc = Self.parseChapterAndProgression(from: server.locatorJSON)
        let localLoc = Self.parseChapterAndProgression(from: local?.locatorJSON)

        // Different chapter on a newer server write is always significant —
        // this is the path Kobo devices hit when their state-update drops
        // ContentSourceProgressPercent. The chapter signal alone tells us
        // the peer moved.
        if let sCh = serverLoc.chapter, let lCh = localLoc.chapter, sCh != lCh {
            return .promptUser(local: localPercentage, server: server)
        }

        // Same chapter (or chapter info unavailable on one side): compare
        // within-chapter progression. Threshold is symmetric — a peer
        // scrolling backwards within the same chapter also counts.
        if let sP = serverLoc.progression, let lP = localLoc.progression {
            if abs(sP - lP) > Self.promptThreshold {
                return .promptUser(local: localPercentage, server: server)
            }
            return .applyServer(progress: server)
        }

        // Neither locator was parseable — fall through to whole-book
        // percentage as a last resort. Matches the v1 behavior so nothing
        // regresses for kosync (which always carries a locator) or for
        // books that were never opened locally.
        let pctDelta = server.percentage - localPercentage
        if pctDelta > Self.promptThreshold {
            return .promptUser(local: localPercentage, server: server)
        }
        if server.percentage > localPercentage {
            return .applyServer(progress: server)
        }
        return .useLocal
    }

    private static func parseChapterAndProgression(
        from json: String?
    ) -> (chapter: String?, progression: Double?) {
        guard let json,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any]
        else { return (nil, nil) }
        let chapter = dict["href"] as? String
        let locations = dict["locations"] as? [String: Any]
        let progression = locations?["progression"] as? Double
        return (chapter, progression)
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
            let pushed: CanonicalProgress
            if proto == .kobo,
               let resolver = spanResolver,
               let fileURL = book.fileURL,
               let augmented = await augmentLocatorWithSpanID(
                   canonical: canonical, fileURL: fileURL, resolver: resolver
               ) {
                pushed = augmented
            } else {
                pushed = canonical
            }
            try await backend.pushProgress(pushed, for: book.identity)
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

    private func augmentLocatorWithSpanID(
        canonical: CanonicalProgress,
        fileURL: URL,
        resolver: any KoboSpanResolving
    ) async -> CanonicalProgress? {
        guard let json = canonical.locatorJSON,
              let data = json.data(using: .utf8),
              var locator = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard let href = locator["href"] as? String,
              var locations = locator["locations"] as? [String: Any],
              let progression = locations["progression"] as? Double
        else { return nil }
        if let existing = locations["cssSelector"] as? String, !existing.isEmpty {
            return nil
        }
        guard let spanID = await resolver.resolve(
            bookFileURL: fileURL, chapterHref: href, progression: progression
        ) else { return nil }
        locations["cssSelector"] = "#" + KoboProgressMapper.escapeCSS(spanID)
        locator["locations"] = locations
        guard let newData = try? JSONSerialization.data(withJSONObject: locator),
              let newJSON = String(data: newData, encoding: .utf8)
        else { return nil }
        return CanonicalProgress(
            percentage: canonical.percentage,
            locatorJSON: newJSON,
            timestamp: canonical.timestamp,
            deviceID: canonical.deviceID,
            deviceName: canonical.deviceName
        )
    }

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
