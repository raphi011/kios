import Testing
import Foundation
@testable import Core

@Suite("KoboClient", .serialized)
struct KoboClientTests {

    init() { MockURLProtocol.handler = nil }

    @Test func initializationReturnsResources() async throws {
        var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let body = #"{ "Resources": { "image_url_template": "https://cwa/{ImageId}/{width}/{height}/false/image.jpg" } }"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let client = makeClient()
        let res = try await client.initialization()
        #expect(capturedPath == "/kobo/TOKEN/v1/initialization")
        #expect(res.imageURLTemplate.contains("{ImageId}"))
    }

    @Test func librarySyncSinglePage() async throws {
        var callCount = 0
        var capturedPath: String?
        var capturedToken: String??
        MockURLProtocol.handler = { req in
            callCount += 1
            capturedPath = req.url?.path
            capturedToken = req.value(forHTTPHeaderField: "x-kobo-synctoken")
            let body = #"""
            [
              { "DeletedTag": { "Tag": { "Id": "t1", "LastModified": "x" } } },
              "ResponseStatus"
            ]
            """#
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "x-kobo-synctoken": "TOKEN_A",
                    "x-kobo-sync": "None"
                ]
            )!
            return (resp, body.data(using: .utf8)!)
        }

        let client = makeClient()
        let result = try await client.librarySync(syncToken: nil)
        #expect(capturedPath == "/kobo/TOKEN/v1/library/sync")
        #expect(capturedToken == .some(nil))
        #expect(callCount == 1)
        #expect(result.entries.count == 1)   // stray skipped
        #expect(result.nextSyncToken == "TOKEN_A")
    }

    @Test func librarySyncFollowsContinueHeader() async throws {
        var callCount = 0
        var secondCallToken: String??
        MockURLProtocol.handler = { req in
            callCount += 1
            if callCount == 1 {
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["x-kobo-synctoken": "T1", "x-kobo-sync": "continue"])!
                return (resp, "[]".data(using: .utf8)!)
            }
            secondCallToken = req.value(forHTTPHeaderField: "x-kobo-synctoken")
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["x-kobo-synctoken": "T2", "x-kobo-sync": "None"])!
            return (resp, "[]".data(using: .utf8)!)
        }
        let client = makeClient()
        let result = try await client.librarySync(syncToken: nil)
        #expect(callCount == 2)
        #expect(secondCallToken == .some("T1"))
        #expect(result.nextSyncToken == "T2")
    }

    // MARK: helpers
    private func makeClient() -> KoboClient {
        let http = HTTPClient(session: MockURLProtocol.session())
        let base = URL(string: "https://cwa/kobo/TOKEN")!
        return KoboClient(baseURL: base, http: http)
    }
}
