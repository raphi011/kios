import Testing
import Foundation
import SwiftData
import Core
@testable import Kios

// MARK: - Shared test backend

/// Records pushes and serves a canned `fetchProgress` result. Actor isolation
/// keeps the recorded `pushes` array Sendable-clean across the closure-based
/// dispatch in `SyncService`.
actor RecordingSyncBackend: SyncBackend {
    var fetchResult: CanonicalProgress?
    private(set) var pushes: [(progress: CanonicalProgress, identity: BookIdentity)] = []

    init(fetchResult: CanonicalProgress? = nil) {
        self.fetchResult = fetchResult
    }

    func authenticate() async throws {}

    func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? {
        fetchResult
    }

    func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        pushes.append((p, id))
    }

    func pushCount() -> Int { pushes.count }
    func firstPush() -> (progress: CanonicalProgress, identity: BookIdentity)? {
        pushes.first
    }
}

@MainActor
final class StubSpanResolver: KoboSpanResolving {
    var result: String?
    var calls: [(bookFileURL: URL, chapterHref: String, progression: Double)] = []
    func resolve(bookFileURL: URL, chapterHref: String, progression: Double) async -> String? {
        calls.append((bookFileURL, chapterHref, progression))
        return result
    }
}

// MARK: - onOpen suite

@Suite("SyncService.onOpen", .serialized)
@MainActor
struct SyncServiceTests {

    @Test func returnsUseLocalWhenNoServerProgress() async throws {
        let env = try Env.make(serverProgress: nil)
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func returnsUseLocalWhenServerIsThisDeviceAndLocalExists() async throws {
        // Same device wrote both: server fetch is redundant, local row is
        // authoritative.
        let server = Self.makeProgress(deviceID: "us", pct: 0.5)
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.5
        )
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func appliesServerWhenServerIsThisDeviceButLocalMissing() async throws {
        // Post-delete redownload (or fresh install on the same physical
        // device): server holds the last position we wrote, but the local
        // ReadingProgress row is gone. Restore silently — never prompt the
        // user about their own write.
        let server = Self.makeProgress(deviceID: "us", pct: 0.5)
        let env = try Env.make(serverProgress: server, deviceID: "us")
        let action = try await env.sync.onOpen(book: env.book)
        if case .applyServer(let s) = action {
            #expect(s.percentage == 0.5)
            #expect(s.deviceID == "us")
        } else {
            Issue.record("expected .applyServer, got \(action)")
        }
    }

    @Test func promptsWhenServerSubstantiallyAhead() async throws {
        // Newer server timestamp, same chapter, large progression delta.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.50,
            timestamp: Self.newer,
            locatorJSON: Self.locatorJSON(chapter: "A", progression: 0.50)
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10,
            localTimestamp: Self.older,
            localLocatorJSON: Self.locatorJSON(chapter: "A", progression: 0.10)
        )
        let action = try await env.sync.onOpen(book: env.book)
        if case .promptUser(let local, let s) = action {
            #expect(local == 0.10)
            #expect(s.deviceID == "other")
        } else {
            Issue.record("expected .promptUser, got \(action)")
        }
    }

    @Test func appliesSilentlyWhenServerSlightlyAhead() async throws {
        // Newer server timestamp, same chapter, tiny progression delta.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.105,
            timestamp: Self.newer,
            locatorJSON: Self.locatorJSON(chapter: "A", progression: 0.105)
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10,
            localTimestamp: Self.older,
            localLocatorJSON: Self.locatorJSON(chapter: "A", progression: 0.10)
        )
        let action = try await env.sync.onOpen(book: env.book)
        if case .applyServer(let s) = action {
            #expect(s.percentage == 0.105)
        } else {
            Issue.record("expected .applyServer, got \(action)")
        }
    }

    @Test func returnsUseLocalWhenServerIsBehind() async throws {
        // Older server timestamp — LWW gate trumps every other signal.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.05,
            timestamp: Self.older,
            locatorJSON: Self.locatorJSON(chapter: "A", progression: 0.05)
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10,
            localTimestamp: Self.newer,
            localLocatorJSON: Self.locatorJSON(chapter: "A", progression: 0.10)
        )
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func promptsWhenChapterDiffersRegardlessOfPercentage() async throws {
        // Reproduces the smoke-test bug: Kobo device push dropped
        // ContentSourceProgressPercent → iOS reads server.percentage = 0.0.
        // Old percentage-only LWW concluded "server is behind"; the
        // chapter-aware path correctly surfaces the structural change.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.0,
            timestamp: Self.newer,
            locatorJSON: Self.locatorJSON(chapter: "B", progression: 0.80)
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.50,
            localTimestamp: Self.older,
            localLocatorJSON: Self.locatorJSON(chapter: "A", progression: 0.30)
        )
        let action = try await env.sync.onOpen(book: env.book)
        if case .promptUser(let local, _) = action {
            #expect(local == 0.50)
        } else {
            Issue.record("expected .promptUser, got \(action)")
        }
    }

    @Test func returnsUseLocalWhenServerTimestampOlderEvenIfChapterDiffers() async throws {
        // Timestamp wins over chapter. An older server write doesn't
        // override a newer local position regardless of structural diff.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.99,
            timestamp: Self.older,
            locatorJSON: Self.locatorJSON(chapter: "Z", progression: 0.99)
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10,
            localTimestamp: Self.newer,
            localLocatorJSON: Self.locatorJSON(chapter: "A", progression: 0.10)
        )
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func fallsBackToPercentageWhenLocatorMissing() async throws {
        // Neither side has a parseable locator JSON: fall back to the v1
        // percentage-only path so behavior doesn't regress.
        let server = Self.makeProgress(
            deviceID: "other", pct: 0.50,
            timestamp: Self.newer,
            locatorJSON: nil
        )
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10,
            localTimestamp: Self.older,
            localLocatorJSON: "{}"
        )
        let action = try await env.sync.onOpen(book: env.book)
        if case .promptUser = action {} else {
            Issue.record("expected .promptUser via percentage fallback, got \(action)")
        }
    }

    // MARK: helpers

    private static let older = Date(timeIntervalSince1970: 1_000_000)
    private static let newer = Date(timeIntervalSince1970: 2_000_000)

    private static func makeProgress(
        deviceID: String,
        pct: Double,
        timestamp: Date = Date(timeIntervalSince1970: 0),
        locatorJSON: String? = nil
    ) -> CanonicalProgress {
        CanonicalProgress(
            percentage: pct,
            locatorJSON: locatorJSON,
            timestamp: timestamp,
            deviceID: deviceID,
            deviceName: "Boox"
        )
    }

    static func locatorJSON(chapter: String, progression: Double) -> String {
        let dict: [String: Any] = [
            "href": chapter,
            "locations": ["progression": progression]
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }

    struct Env {
        let sync: SyncService
        let book: Book

        @MainActor
        static func make(
            serverProgress: CanonicalProgress?,
            deviceID: String = "us",
            localPercentage: Double? = nil,
            localTimestamp: Date = .now,
            localLocatorJSON: String = "{}",
            bookHasHash: Bool = true
        ) throws -> Env {
            let container = try ModelContainer(
                for: Book.self, ReadingProgress.self, Download.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)

            let backend = RecordingSyncBackend(fetchResult: serverProgress)
            let sync = SyncService(
                backend: backend,
                context: context,
                deviceID: deviceID,
                deviceName: "iPhone"
            )

            let book = Book(
                serverID: "id",
                serverIDProtocol: "kosync",
                title: "T",
                authors: [],
                opdsHref: URL(string: "https://x")!,
                acquisitionURL: URL(string: "https://x")!,
                format: .epub,
                koboBookUUID: nil,
                archived: false,
                partialMD5: bookHasHash ? "abc" : nil
            )
            context.insert(book)
            if let p = localPercentage {
                context.insert(ReadingProgress(
                    bookID: book.id,
                    locatorJSON: localLocatorJSON,
                    koSyncProgressString: nil,
                    koboLocationSource: nil,
                    koboLocationValue: nil,
                    percentage: p,
                    updatedAt: localTimestamp,
                    deviceID: deviceID,
                    pendingUpload: false
                ))
            }
            try context.save()
            return Env(sync: sync, book: book)
        }
    }
}

// MARK: - bufferLocator / flushPendingProgress suite

@Suite("SyncService.bufferFlush", .serialized)
@MainActor
struct SyncServiceBufferFlushTests {

    private static func makeBook(withHash: Bool = true) -> Book {
        Book(
            serverID: "id",
            serverIDProtocol: "kosync",
            title: "T",
            authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            partialMD5: withHash ? "abc" : nil
        )
    }

    @MainActor
    private static func makeEnv() throws -> (sync: SyncService, book: Book, context: ModelContext, backend: RecordingSyncBackend) {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let backend = RecordingSyncBackend()
        let sync = SyncService(
            backend: backend,
            context: context,
            deviceID: "us",
            deviceName: "iPhone"
        )
        let book = makeBook()
        context.insert(book)
        try context.save()
        return (sync, book, context, backend)
    }

    @Test func bufferLocatorWritesLocallyWithoutNetwork() async throws {
        let (sync, book, context, backend) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#, percentage: 0.5
        )

        let bookID = book.id
        let rows = try context.fetch(FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(rows.count == 1)
        #expect(rows[0].pendingUpload == true)
        #expect(rows[0].percentage == 0.5)
        #expect(await backend.pushCount() == 0)
    }

    @Test func flushPendingProgressPushesAndClearsFlag() async throws {
        let (sync, book, context, backend) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#, percentage: 0.5
        )
        await sync.flushPendingProgress(for: book)

        let bookID = book.id
        let rows = try context.fetch(FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(rows.count == 1)
        #expect(rows[0].pendingUpload == false)
        let pushed = await backend.firstPush()
        #expect(await backend.pushCount() == 1)
        // SyncService fills deviceName from its identity, not from the row.
        #expect(pushed?.progress.deviceName == "iPhone")
        #expect(pushed?.progress.deviceID == "us")
        #expect(pushed?.progress.percentage == 0.5)
    }

    @Test func flushPendingProgressNoOpWhenAlreadyClean() async throws {
        let (sync, book, _, backend) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#, percentage: 0.5
        )
        // First flush — sends request and clears flag.
        await sync.flushPendingProgress(for: book)
        #expect(await backend.pushCount() == 1)

        // Second flush — row is already clean, no second push.
        await sync.flushPendingProgress(for: book)
        #expect(await backend.pushCount() == 1)
    }

    @Test func flushAllPendingRetriesAllPendingRows() async throws {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let backend = RecordingSyncBackend()
        let sync = SyncService(
            backend: backend,
            context: context,
            deviceID: "us",
            deviceName: "iPhone"
        )

        // Two separate books, each with a pending row.
        let book1 = Book(
            serverID: "id1", serverIDProtocol: "kosync",
            title: "T1", authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub, koboBookUUID: nil, archived: false,
            partialMD5: "hash1"
        )
        let book2 = Book(
            serverID: "id2", serverIDProtocol: "kosync",
            title: "T2", authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub, koboBookUUID: nil, archived: false,
            partialMD5: "hash2"
        )
        context.insert(book1)
        context.insert(book2)

        context.insert(ReadingProgress(
            bookID: book1.id,
            locatorJSON: "{}", koSyncProgressString: nil,
            koboLocationSource: nil, koboLocationValue: nil,
            percentage: 0.3, updatedAt: .now, deviceID: "us",
            pendingUpload: true
        ))
        context.insert(ReadingProgress(
            bookID: book2.id,
            locatorJSON: "{}", koSyncProgressString: nil,
            koboLocationSource: nil, koboLocationValue: nil,
            percentage: 0.6, updatedAt: .now, deviceID: "us",
            pendingUpload: true
        ))
        try context.save()

        await sync.flushAllPending()

        #expect(await backend.pushCount() == 2)
        let rows = try context.fetch(FetchDescriptor<ReadingProgress>())
        #expect(rows.allSatisfy { !$0.pendingUpload })
    }

    // MARK: - Kobo span resolver injection

    @MainActor
    private static func makeKoboEnv(
        resolver: any KoboSpanResolving
    ) throws -> (sync: SyncService, book: Book, context: ModelContext, backend: RecordingSyncBackend) {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let backend = RecordingSyncBackend()
        let sync = SyncService(
            backend: backend,
            context: context,
            deviceID: "us",
            deviceName: "iPhone",
            spanResolver: resolver
        )
        // filename non-nil so Book.fileURL is non-nil; resolver is stubbed
        // and never opens the file, so no disk I/O needed.
        let book = Book(
            serverID: "id",
            serverIDProtocol: "kobo",
            title: "T",
            authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: "uuid-1",
            archived: false,
            filename: "test.epub",
            partialMD5: "abc"
        )
        context.insert(book)
        try context.save()
        return (sync, book, context, backend)
    }

    @Test func koboPushWithResolverInjectsCSSSelector() async throws {
        let stub = StubSpanResolver()
        stub.result = "kobo.10.1"
        let (sync, book, _, backend) = try Self.makeKoboEnv(resolver: stub)

        let locator = #"{"href":"OEBPS/text/ch10.xhtml","locations":{"progression":0.5}}"#
        sync.bufferLocator(book: book, locatorJSON: locator, percentage: 0.5)
        await sync.flushPendingProgress(for: book)

        let pushed = await backend.firstPush()
        let json = pushed?.progress.locatorJSON ?? ""
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let locations = obj?["locations"] as? [String: Any]
        #expect((locations?["cssSelector"] as? String) == #"#kobo\.10\.1"#)
        #expect((locations?["progression"] as? Double) == 0.5)
        #expect((obj?["href"] as? String) == "OEBPS/text/ch10.xhtml")
        #expect(stub.calls.count == 1)
        #expect(stub.calls.first?.chapterHref == "OEBPS/text/ch10.xhtml")
        #expect(stub.calls.first?.progression == 0.5)
    }

    @Test func koboPushWithResolverReturningNilLeavesLocatorUnchanged() async throws {
        let stub = StubSpanResolver()
        stub.result = nil
        let (sync, book, _, backend) = try Self.makeKoboEnv(resolver: stub)

        let locator = #"{"href":"OEBPS/text/ch10.xhtml","locations":{"progression":0.5}}"#
        sync.bufferLocator(book: book, locatorJSON: locator, percentage: 0.5)
        await sync.flushPendingProgress(for: book)

        let pushed = await backend.firstPush()
        let json = pushed?.progress.locatorJSON ?? ""
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let locations = obj?["locations"] as? [String: Any]
        #expect(locations?["cssSelector"] == nil)
        #expect((locations?["progression"] as? Double) == 0.5)
        #expect(stub.calls.count == 1)
    }

    @Test func koboPushWhenLocatorAlreadyHasCSSSelectorPreservesOriginal() async throws {
        let stub = StubSpanResolver()
        stub.result = "kobo.99.9"
        let (sync, book, _, backend) = try Self.makeKoboEnv(resolver: stub)

        // Build locator via JSONSerialization so the backslash escapes are
        // unambiguous on the wire (raw-string `\` collides with `\.` in JSON).
        let preExisting = "#" + KoboProgressMapper.escapeCSS("kobo.5.2")
        let obj0: [String: Any] = [
            "href": "OEBPS/text/ch10.xhtml",
            "locations": ["progression": 0.5, "cssSelector": preExisting],
        ]
        let locator = String(
            data: try JSONSerialization.data(withJSONObject: obj0),
            encoding: .utf8
        )!
        sync.bufferLocator(book: book, locatorJSON: locator, percentage: 0.5)
        await sync.flushPendingProgress(for: book)

        let pushed = await backend.firstPush()
        let json = pushed?.progress.locatorJSON ?? ""
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let locations = obj?["locations"] as? [String: Any]
        #expect((locations?["cssSelector"] as? String) == preExisting)
        #expect(stub.calls.isEmpty)
    }
}
