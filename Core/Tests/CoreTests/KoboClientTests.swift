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

    // MARK: helpers
    private func makeClient() -> KoboClient {
        let http = HTTPClient(session: MockURLProtocol.session())
        let base = URL(string: "https://cwa/kobo/TOKEN")!
        return KoboClient(baseURL: base, http: http)
    }
}
