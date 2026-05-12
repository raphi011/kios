import Testing
import Foundation
import SwiftData
import Core
@testable import iOSReader

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

    @Test func returnsUseLocalWhenServerIsThisDevice() async throws {
        let server = Self.makeProgress(deviceID: "us", pct: 0.5)
        let env = try Env.make(serverProgress: server, deviceID: "us")
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func promptsWhenServerSubstantiallyAhead() async throws {
        let server = Self.makeProgress(deviceID: "other", pct: 0.50)
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10
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
        // 10.5% vs 10.0% — within 1% threshold, but server > local.
        let server = Self.makeProgress(deviceID: "other", pct: 0.105)
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10
        )
        let action = try await env.sync.onOpen(book: env.book)
        if case .applyServer(let s) = action {
            #expect(s.percentage == 0.105)
        } else {
            Issue.record("expected .applyServer, got \(action)")
        }
    }

    @Test func returnsUseLocalWhenServerIsBehind() async throws {
        let server = Self.makeProgress(deviceID: "other", pct: 0.05)
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10
        )
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    // MARK: helpers

    private static func makeProgress(deviceID: String, pct: Double) -> CanonicalProgress {
        CanonicalProgress(
            percentage: pct,
            locatorJSON: nil,
            timestamp: Date(timeIntervalSince1970: 0),
            deviceID: deviceID,
            deviceName: "Boox"
        )
    }

    struct Env {
        let sync: SyncService
        let book: Book

        @MainActor
        static func make(
            serverProgress: CanonicalProgress?,
            deviceID: String = "us",
            localPercentage: Double? = nil,
            bookHasHash: Bool = true
        ) throws -> Env {
            let container = try ModelContainer(
                for: Book.self, ReadingProgress.self, Download.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)

            let backend = RecordingSyncBackend(fetchResult: serverProgress)
            let sync = SyncService(
                backendForProtocol: { _ in backend },
                context: context,
                activeProtocol: .kosync,
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
                    locatorJSON: "{}",
                    koSyncProgressString: nil,
                    koboLocationSource: nil,
                    koboLocationValue: nil,
                    percentage: p,
                    updatedAt: .now,
                    deviceID: deviceID,
                    pendingUpload: false,
                    pendingProtocol: nil
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
    private static func makeEnv(
        activeProtocol: SyncProtocol = .kosync
    ) throws -> (sync: SyncService, book: Book, context: ModelContext, backend: RecordingSyncBackend) {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let backend = RecordingSyncBackend()
        let sync = SyncService(
            backendForProtocol: { _ in backend },
            context: context,
            activeProtocol: activeProtocol,
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
        #expect(rows[0].pendingProtocol == "kosync")
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
        #expect(rows[0].pendingProtocol == nil)
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
            backendForProtocol: { _ in backend },
            context: context,
            activeProtocol: .kosync,
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
            pendingUpload: true, pendingProtocol: "kosync"
        ))
        context.insert(ReadingProgress(
            bookID: book2.id,
            locatorJSON: "{}", koSyncProgressString: nil,
            koboLocationSource: nil, koboLocationValue: nil,
            percentage: 0.6, updatedAt: .now, deviceID: "us",
            pendingUpload: true, pendingProtocol: "kosync"
        ))
        try context.save()

        await sync.flushAllPending()

        #expect(await backend.pushCount() == 2)
        let rows = try context.fetch(FetchDescriptor<ReadingProgress>())
        #expect(rows.allSatisfy { !$0.pendingUpload })
    }

    // MARK: - Protocol pinning

    /// Load-bearing test for Phase 7.4. After buffering under kosync, the
    /// row's `pendingProtocol` is "kosync". Even if `SyncService` is
    /// reconfigured with an active protocol of `.kobo` (simulating a mid-
    /// buffer protocol switch), the flush must route to the kosync backend,
    /// not the kobo one. The closure's `proto` argument is the assertion
    /// surface: we route per-protocol to distinct recording backends and
    /// verify only the kosync backend received the push.
    @Test func bufferThenSwitchProtocolStillFlushesToOriginalBackend() async throws {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let kosyncBackend = RecordingSyncBackend()
        let koboBackend = RecordingSyncBackend()
        let dispatch: @MainActor (SyncProtocol) throws -> any SyncBackend = { proto in
            switch proto {
            case .kosync: return kosyncBackend
            case .kobo: return koboBackend
            }
        }

        let book = Book(
            serverID: "id", serverIDProtocol: "kosync",
            title: "T", authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub, koboBookUUID: "uuid-1", archived: false,
            partialMD5: "abc"
        )
        context.insert(book)
        try context.save()

        // 1. Buffer while active protocol is kosync — pins pendingProtocol.
        let kosyncService = SyncService(
            backendForProtocol: dispatch,
            context: context,
            activeProtocol: .kosync,
            deviceID: "us",
            deviceName: "iPhone"
        )
        kosyncService.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#, percentage: 0.5
        )

        // Sanity: pin captured.
        let bookID = book.id
        let row = try context.fetch(FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )).first
        #expect(row?.pendingProtocol == "kosync")

        // 2. Simulate the user switching to kobo before the flush fires.
        //    A new SyncService is constructed (mimicking AppEnvironment's
        //    re-boot) with activeProtocol = .kobo, but the same dispatch
        //    closure backs both protocol lookups.
        let koboService = SyncService(
            backendForProtocol: dispatch,
            context: context,
            activeProtocol: .kobo,
            deviceID: "us",
            deviceName: "iPhone"
        )

        // 3. Flush under the new (kobo-active) service. The pinned protocol
        //    on the row is "kosync", so the kosync backend must receive the
        //    push and the kobo backend must NOT.
        await koboService.flushPendingProgress(for: book)

        let kosyncPush = await kosyncBackend.firstPush()
        #expect(await kosyncBackend.pushCount() == 1)
        #expect(await koboBackend.pushCount() == 0)
        #expect(kosyncPush?.progress.percentage == 0.5)

        // Row is cleared.
        let finalRow = try context.fetch(FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )).first
        #expect(finalRow?.pendingUpload == false)
        #expect(finalRow?.pendingProtocol == nil)
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
            backendForProtocol: { _ in backend },
            context: context,
            activeProtocol: .kobo,
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
