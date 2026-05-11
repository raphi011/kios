import Testing
import Foundation
import SwiftData
import Core
@testable import iOSReader

@Suite("SyncService.onOpen", .serialized)
@MainActor
struct SyncServiceTests {

    init() { MockURLProtocol.handler = nil }

    @Test func returnsUseLocalWhenNoServerProgress() async throws {
        let env = try Env.make(serverProgress: nil)
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func returnsUseLocalWhenServerIsThisDevice() async throws {
        let server = Self.makeProgress(device: "us", pct: 0.5)
        let env = try Env.make(serverProgress: server, deviceID: "us")
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func promptsWhenServerSubstantiallyAhead() async throws {
        let server = Self.makeProgress(device: "other", pct: 0.50)
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
        let server = Self.makeProgress(device: "other", pct: 0.105)
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
        let server = Self.makeProgress(device: "other", pct: 0.05)
        let env = try Env.make(
            serverProgress: server, deviceID: "us", localPercentage: 0.10
        )
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    @Test func returnsUseLocalWhenBookHasNoHash() async throws {
        let env = try Env.make(serverProgress: nil, bookHasHash: false)
        let action = try await env.sync.onOpen(book: env.book)
        #expect(action == .useLocal)
    }

    // MARK: helpers

    private static func makeProgress(device: String, pct: Double) -> ProgressDownload {
        ProgressDownload(
            document: "abc", progress: "1:0.0",
            percentage: pct,
            device: "Boox", deviceID: device, timestamp: 0
        )
    }

    struct Env {
        let sync: SyncService
        let book: Book

        @MainActor
        static func make(
            serverProgress: ProgressDownload?,
            deviceID: String = "us",
            localPercentage: Double? = nil,
            bookHasHash: Bool = true
        ) throws -> Env {
            let container = try ModelContainer(
                for: Book.self, ReadingProgress.self, Download.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)

            // Stub the URLSession via MockURLProtocol.
            MockURLProtocol.handler = { req in
                if req.httpMethod == "GET", let p = serverProgress {
                    let body = try JSONEncoder().encode(p)
                    let resp = HTTPURLResponse(
                        url: req.url!, statusCode: 200,
                        httpVersion: "HTTP/1.1", headerFields: nil
                    )!
                    return (resp, body)
                }
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 404,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                return (resp, Data())
            }
            let kosync = KOSyncClient(
                baseURL: URL(string: "https://x/kosync")!,
                http: HTTPClient(
                    session: MockURLProtocol.session(),
                    credentials: .init(username: "u", password: "p")
                )
            )

            let sync = SyncService(
                kosync: kosync, context: context,
                deviceID: deviceID, deviceName: "iPhone"
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
                    koSyncProgressString: "0|0.0",
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

// MARK: - SyncService buffer/flush tests

@Suite("SyncService.bufferFlush", .serialized)
@MainActor
struct SyncServiceBufferFlushTests {

    init() { MockURLProtocol.handler = nil }

    // MARK: helpers

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
        recordPutRequests: Bool = false
    ) throws -> (sync: SyncService, book: Book, context: ModelContext, putCount: () -> Int) {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        var putRequests = 0
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PUT" {
                putRequests += 1
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                // kosync PUT returns the progress object echoed back
                let body = #"{"document":"abc","progress":"0|0.0","percentage":0.5,"device":"iPhone","device_id":"us","timestamp":1}"#.data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data())
        }

        let kosync = KOSyncClient(
            baseURL: URL(string: "https://x/kosync")!,
            http: HTTPClient(
                session: MockURLProtocol.session(),
                credentials: .init(username: "u", password: "p")
            )
        )
        let sync = SyncService(
            kosync: kosync, context: context,
            deviceID: "us", deviceName: "iPhone"
        )
        let book = makeBook()
        context.insert(book)
        try context.save()

        return (sync, book, context, { putRequests })
    }

    @Test func bufferLocatorWritesLocallyWithoutNetwork() async throws {
        let (sync, book, context, putCount) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#,
            chapter: 0, intraProgression: 0.5, percentage: 0.5
        )

        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let rows = try context.fetch(descriptor)
        #expect(rows.count == 1)
        #expect(rows[0].pendingUpload == true)
        #expect(rows[0].percentage == 0.5)
        #expect(putCount() == 0)
    }

    @Test func flushPendingProgressPushesAndClearsFlag() async throws {
        let (sync, book, context, putCount) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#,
            chapter: 0, intraProgression: 0.5, percentage: 0.5
        )
        await sync.flushPendingProgress(for: book)

        let bookID = book.id
        let descriptor = FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let rows = try context.fetch(descriptor)
        #expect(rows.count == 1)
        #expect(rows[0].pendingUpload == false)
        #expect(putCount() == 1)
    }

    @Test func flushPendingProgressNoOpWhenAlreadyClean() async throws {
        let (sync, book, _, putCount) = try Self.makeEnv()

        sync.bufferLocator(
            book: book, locatorJSON: #"{"href":"/1"}"#,
            chapter: 0, intraProgression: 0.5, percentage: 0.5
        )
        // First flush — sends request and clears flag.
        await sync.flushPendingProgress(for: book)
        #expect(putCount() == 1)

        // Second flush — row is already clean, no second PUT.
        await sync.flushPendingProgress(for: book)
        #expect(putCount() == 1)
    }

    @Test func flushAllPendingRetriesAllPendingRows() async throws {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        var putRequests = 0
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PUT" {
                putRequests += 1
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                let body = #"{"document":"abc","progress":"0|0.0","percentage":0.3,"device":"iPhone","device_id":"us","timestamp":1}"#.data(using: .utf8)!
                return (resp, body)
            }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data())
        }

        let kosync = KOSyncClient(
            baseURL: URL(string: "https://x/kosync")!,
            http: HTTPClient(
                session: MockURLProtocol.session(),
                credentials: .init(username: "u", password: "p")
            )
        )
        let sync = SyncService(
            kosync: kosync, context: context,
            deviceID: "us", deviceName: "iPhone"
        )

        // Two separate books, each with a pending row.
        let book1 = Book(
            serverID: "id1",
            serverIDProtocol: "kosync",
            title: "T1",
            authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            partialMD5: "hash1"
        )
        let book2 = Book(
            serverID: "id2",
            serverIDProtocol: "kosync",
            title: "T2",
            authors: [],
            opdsHref: URL(string: "https://x")!,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            partialMD5: "hash2"
        )
        context.insert(book1)
        context.insert(book2)

        context.insert(ReadingProgress(
            bookID: book1.id,
            locatorJSON: "{}",
            koSyncProgressString: "0|0.3",
            koboLocationSource: nil,
            koboLocationValue: nil,
            percentage: 0.3,
            updatedAt: .now,
            deviceID: "us",
            pendingUpload: true,
            pendingProtocol: "kosync"
        ))
        context.insert(ReadingProgress(
            bookID: book2.id,
            locatorJSON: "{}",
            koSyncProgressString: "0|0.6",
            koboLocationSource: nil,
            koboLocationValue: nil,
            percentage: 0.6,
            updatedAt: .now,
            deviceID: "us",
            pendingUpload: true,
            pendingProtocol: "kosync"
        ))
        try context.save()

        await sync.flushAllPending()

        #expect(putRequests == 2)

        let rows = try context.fetch(FetchDescriptor<ReadingProgress>())
        #expect(rows.allSatisfy { !$0.pendingUpload })
    }
}
