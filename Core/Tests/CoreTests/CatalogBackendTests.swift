import Testing
import Foundation
@testable import Core

@Suite("CatalogBackend", .serialized)
struct CatalogBackendTests {

    init() { MockURLProtocol.handler = nil }

    @Test func entryConstruction() {
        let entry = CatalogEntry(
            serverID: "id-1",
            title: "Test",
            authors: ["A"],
            identity: BookIdentity(koboBookUUID: "uuid"),
            downloadURL: URL(string: "https://example.com/d")!,
            format: .epub,
            thumbnailURL: nil
        )
        #expect(entry.title == "Test")
        #expect(entry.identity.koboBookUUID == "uuid")
    }

    @Test func koboBackendProbeReachable() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/v1/initialization") == true)
            let body = #"{ "Resources": { "image_url_template": "x" } }"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let backend = makeKoboBackend()
        // probe() must not throw when the server returns 200
        try await backend.probe()
    }

    @Test func koboBackendProbeUnreachableThrows() async throws {
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let backend = makeKoboBackend()
        // probe() must throw when the server returns a non-success status
        await #expect(throws: (any Error).self) {
            try await backend.probe()
        }
    }

    // MARK: helpers

    private func makeKoboBackend() -> KoboBackend {
        let http = HTTPClient(session: MockURLProtocol.session())
        let kc = KoboClient(
            baseURL: URL(string: "https://cwa/kobo/T")!,
            http: http,
            deviceID: "D"
        )
        return KoboBackend(client: kc, deviceID: "D", deviceName: "iPhone", imageURLTemplate: nil)
    }
}
