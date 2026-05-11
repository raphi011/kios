import Testing
import Foundation
@testable import Core

@Suite("KoboBackend", .serialized)
struct KoboBackendTests {

    init() { MockURLProtocol.handler = nil }

    @Test func authenticateHitsInitialization() async throws {
        var hit = false
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/v1/initialization") == true)
            hit = true
            let body = #"{ "Resources": { "image_url_template": "x" } }"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let backend = makeBackend()
        try await backend.authenticate()
        #expect(hit)
    }

    @Test func fetchProgressReturnsCanonical() async throws {
        MockURLProtocol.handler = { req in
            let body = #"""
            [{
              "EntitlementId":"u1","Created":"x","LastModified":"2026-05-11T20:00:00Z","PriorityTimestamp":"x",
              "StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},
              "Statistics":{"LastModified":"x"},
              "CurrentBookmark":{"LastModified":"x","ProgressPercent":45.0,"ContentSourceProgressPercent":16.0,
                                 "Location":{"Value":"kobo.10.1","Type":"KoboSpan","Source":"f_0035.xhtml"}}
            }]
            """#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let backend = makeBackend()
        let id = BookIdentity(partialMD5: nil, koboBookUUID: "u1")
        let p = try await backend.fetchProgress(for: id)
        #expect(p?.percentage == 0.16)
        #expect(p?.deviceID == "kobo-peer")
        // locatorJSON is a JSON-encoded string, so the cssSelector's literal
        // `\.` escape appears as `\\.` in the encoded form.
        #expect(p?.locatorJSON?.contains(#"#kobo\\.10\\.1"#) == true)
    }

    @Test func fetchProgressMissingIdentityThrows() async throws {
        let backend = makeBackend()
        do {
            _ = try await backend.fetchProgress(for: BookIdentity())
            Issue.record("expected throw")
        } catch BackendError.identityMissing(let field) {
            #expect(field == "koboBookUUID")
        }
    }

    // MARK: helpers
    private func makeBackend() -> KoboBackend {
        let http = HTTPClient(session: MockURLProtocol.session())
        let kc = KoboClient(
            baseURL: URL(string: "https://cwa/kobo/T")!,
            http: http
        )
        return KoboBackend(client: kc, deviceID: "D", deviceName: "iPhone")
    }
}
