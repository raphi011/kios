import Testing
import Foundation
@testable import Core

@Suite("HTTPClient", .serialized)
struct HTTPClientTests {

    init() { MockURLProtocol.handler = nil }

    @Test func attachesBasicAuthHeader() async throws {
        var capturedAuth: String?
        MockURLProtocol.handler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (Self.ok(req.url!), Data())
        }
        let client = HTTPClient(
            session: MockURLProtocol.session(),
            credentials: .init(username: "alice", password: "secret")
        )
        _ = try await client.data(for: URLRequest(url: URL(string: "https://x/y")!))
        // Basic auth: base64("alice:secret") = "YWxpY2U6c2VjcmV0"
        #expect(capturedAuth == "Basic YWxpY2U6c2VjcmV0")
    }

    @Test func mapsHTTPErrorOn401() async {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data())
        }
        let client = HTTPClient(
            session: MockURLProtocol.session(),
            credentials: .init(username: "alice", password: "x")
        )
        await #expect(throws: HTTPError.unauthorized) {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://x/y")!))
        }
    }

    @Test func mapsHTTPErrorOn404() async {
        MockURLProtocol.handler = { req in
            (Self.status(404, req.url!), Data())
        }
        let client = HTTPClient(session: MockURLProtocol.session(), credentials: nil)
        await #expect(throws: HTTPError.notFound) {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://x/y")!))
        }
    }

    @Test func wrapsServerErrorWithStatusAndBody() async throws {
        MockURLProtocol.handler = { req in
            (Self.status(500, req.url!), Data("oops".utf8))
        }
        let client = HTTPClient(session: MockURLProtocol.session(), credentials: nil)
        do {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://x")!))
            Issue.record("expected throw")
        } catch HTTPError.server(let status, let body) {
            #expect(status == 500)
            #expect(String(data: body, encoding: .utf8) == "oops")
        }
    }

    @Test func wrapsTransportError() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = HTTPClient(session: MockURLProtocol.session(), credentials: nil)
        do {
            _ = try await client.data(for: URLRequest(url: URL(string: "https://x")!))
            Issue.record("expected throw")
        } catch HTTPError.transport(let urlError) {
            #expect(urlError.code == .notConnectedToInternet)
        }
    }

    @Test func skipsAuthHeaderWhenNoCredentials() async throws {
        var capturedAuth: String?
        MockURLProtocol.handler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            return (Self.ok(req.url!), Data())
        }
        let client = HTTPClient(session: MockURLProtocol.session(), credentials: nil)
        _ = try await client.data(for: URLRequest(url: URL(string: "https://x")!))
        #expect(capturedAuth == nil)
    }

    private static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
    private static func status(_ code: Int, _ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
