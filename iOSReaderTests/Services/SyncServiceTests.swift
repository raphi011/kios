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
                for: Book.self, ReadingProgress.self, Download.self, LibraryServer.self,
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
                serverID: "id", title: "T", authors: [],
                opdsHref: URL(string: "https://x")!,
                acquisitionURL: URL(string: "https://x")!,
                format: .epub,
                partialMD5: bookHasHash ? "abc" : nil
            )
            context.insert(book)
            if let p = localPercentage {
                context.insert(ReadingProgress(
                    bookID: book.id, locatorJSON: "{}",
                    percentage: p, updatedAt: .now,
                    deviceID: deviceID, pendingUpload: false
                ))
            }
            try context.save()
            return Env(sync: sync, book: book)
        }
    }
}
