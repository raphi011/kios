import Testing
import Foundation
@testable import Core

@Suite("KOSyncClient", .serialized)
struct KOSyncClientTests {

    init() { MockURLProtocol.handler = nil }

    @Test func authenticateReturnsTrueOn200() async throws {
        var capturedPath: String?
        var capturedMethod: String?
        var capturedAccept: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedAccept = req.value(forHTTPHeaderField: "Accept")
            return (Self.ok(req.url!), Data())
        }
        let client = makeClient()
        let ok = try await client.authenticate()
        #expect(ok == true)
        #expect(capturedPath == "/kosync/users/auth")
        #expect(capturedMethod == "GET")
        #expect(capturedAccept == "application/vnd.koreader.v1+json")
    }

    @Test func authenticateThrowsOn401() async {
        MockURLProtocol.handler = { req in (Self.status(401, req.url!), Data()) }
        let client = makeClient()
        await #expect(throws: HTTPError.unauthorized) {
            _ = try await client.authenticate()
        }
    }

    @Test func putProgressSerializesAllFields() async throws {
        var bodyJSON: [String: Any]?
        var capturedPath: String?
        var capturedMethod: String?
        var capturedContentType: String?

        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type")

            // URLProtocol delivers PUT/POST bodies via httpBodyStream, not httpBody.
            if let stream = req.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = stream.read(&buf, maxLength: buf.count)
                let data = Data(buf.prefix(n))
                bodyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (Self.ok(req.url!), Data())
        }

        let client = makeClient()
        try await client.putProgress(.init(
            document: "abc123",
            progress: "5:0.42",
            percentage: 0.18,
            device: "iPhone 15",
            deviceID: "device-uuid"
        ))

        #expect(capturedPath == "/kosync/syncs/progress")
        #expect(capturedMethod == "PUT")
        #expect(capturedContentType == "application/json")
        #expect(bodyJSON?["document"] as? String == "abc123")
        #expect(bodyJSON?["progress"] as? String == "5:0.42")
        #expect((bodyJSON?["percentage"] as? Double) == 0.18)
        #expect(bodyJSON?["device"] as? String == "iPhone 15")
        #expect(bodyJSON?["device_id"] as? String == "device-uuid")
    }

    @Test func getProgressReturnsNilOn404() async throws {
        MockURLProtocol.handler = { req in (Self.status(404, req.url!), Data()) }
        let client = makeClient()
        let p = try await client.getProgress(documentHash: "missing")
        #expect(p == nil)
    }

    @Test func getProgressDecodesPayload() async throws {
        let body = """
        {"document":"abc","progress":"5:0.42","percentage":0.18,
         "device":"Boox","device_id":"d","timestamp":1700000000}
        """
        var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (Self.ok(req.url!), Data(body.utf8))
        }
        let client = makeClient()
        let p = try await client.getProgress(documentHash: "abc")
        #expect(p?.document == "abc")
        #expect(p?.progress == "5:0.42")
        #expect(p?.percentage == 0.18)
        #expect(p?.device == "Boox")
        #expect(p?.deviceID == "d")
        #expect(p?.timestamp == 1700000000)
        #expect(capturedPath == "/kosync/syncs/progress/abc")
    }

    @Test func getProgressEscapesDocumentHash() async throws {
        var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (Self.status(404, req.url!), Data())
        }
        let client = makeClient()
        _ = try await client.getProgress(documentHash: "abc/def?q")
        // URL-path escaping leaves '/' alone but escapes '?'.
        #expect(capturedPath?.contains("abc/def") == true)
        #expect(capturedPath?.contains("%3Fq") == true)
    }

    @Test func putProgressPropagatesUnauthorized() async {
        MockURLProtocol.handler = { req in (Self.status(401, req.url!), Data()) }
        let client = makeClient()
        await #expect(throws: HTTPError.unauthorized) {
            try await client.putProgress(.init(
                document: "x", progress: "0:0.0", percentage: 0,
                device: "d", deviceID: "id"
            ))
        }
    }

    // MARK: helpers
    private func makeClient() -> KOSyncClient {
        let http = HTTPClient(
            session: MockURLProtocol.session(),
            credentials: .init(username: "alice", password: "secret")
        )
        return KOSyncClient(baseURL: URL(string: "https://example/kosync")!, http: http)
    }
    private static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    private static func status(_ code: Int, _ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
