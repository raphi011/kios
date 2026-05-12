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

    @Test func fetchProgressUsesDeviceIdWhenServerReturnsIt() async throws {
        MockURLProtocol.handler = { req in
            let body = #"""
            [{
              "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
              "StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},
              "Statistics":{"LastModified":"x"},
              "CurrentBookmark":{"LastModified":"x","ProgressPercent":50.0,"DeviceId":"peer-device-id"}
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
        #expect(p?.deviceID == "peer-device-id")
    }

    @Test func fetchProgressFallsBackToKoboPeerWhenDeviceIdMissing() async throws {
        MockURLProtocol.handler = { req in
            let body = #"""
            [{
              "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
              "StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},
              "Statistics":{"LastModified":"x"},
              "CurrentBookmark":{"LastModified":"x","ProgressPercent":50.0}
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
        #expect(p?.deviceID == "kobo-peer")
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

    @Test func pushProgressSendsExpectedBody() async throws {
        // Capture body outside the handler — URLProtocol delivers PUT bodies
        // via httpBodyStream, so the request must be drained inside the
        // handler (see MockURLProtocol.readBodyStream()).
        nonisolated(unsafe) var sentBody: Data?
        MockURLProtocol.handler = { req in
            sentBody = req.readBodyStream()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"RequestResult":"Success","UpdateResults":[]}"#.utf8)
            )
        }
        let backend = makeBackend()
        let id = BookIdentity(partialMD5: nil, koboBookUUID: "u1")
        let locatorJSON = KoboProgressMapper.toLocator(
            source: "f_0035.xhtml",
            type: "KoboSpan",
            value: "kobo.10.1",
            progressPercent: 45,
            totalPercent: 16
        )
        let p = CanonicalProgress(
            percentage: 0.16,
            locatorJSON: locatorJSON,
            timestamp: Date(),
            deviceID: "D",
            deviceName: "iPhone"
        )
        try await backend.pushProgress(p, for: id)
        let body = String(data: sentBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"ReadingStates\""))
        #expect(body.contains("\"ProgressPercent\":45"))
        #expect(body.contains("\"Value\":\"kobo.10.1\""))
    }

    @Test func listLibraryFromSync() async throws {
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { req in
            callCount += 1
            if req.url?.path.hasSuffix("/v1/library/sync") == true {
                let body = #"""
                [{
                  "NewEntitlement": {
                    "BookEntitlement": {
                      "Id":"u1","CrossRevisionId":"u1","RevisionId":"u1","Accessibility":"Full",
                      "Status":"Active","IsRemoved":false,"Created":"x","LastModified":"x"
                    },
                    "BookMetadata": {
                      "EntitlementId":"u1","Title":"Test","Contributors":["Author One"],
                      "CoverImageId":"cov1",
                      "DownloadUrls":[{"Format":"KEPUB","Url":"https://cwa/download/1/kepub","Size":100,"Platform":"Generic"}]
                    },
                    "ReadingState": {
                      "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
                      "StatusInfo":{"LastModified":"x","Status":"ReadyToRead","TimesStartedReading":0},
                      "Statistics":{"LastModified":"x"},
                      "CurrentBookmark":{"LastModified":"x"}
                    }
                  }
                }]
                """#
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["x-kobo-synctoken": "T", "x-kobo-sync": "None"])!,
                        body.data(using: .utf8)!)
            }
            // Initialization
            let body = #"{ "Resources": { "image_url_template": "https://cwa/{ImageId}/{width}/{height}/false/image.jpg" } }"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        let backend = KoboBackend(
            client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: HTTPClient(session: MockURLProtocol.session()), deviceID: "D"),
            deviceID: "D", deviceName: "iPhone", imageURLTemplate: nil
        )
        try await backend.authenticate()       // populates image template
        let entries = try await backend.listLibrary()
        // Initialization + library sync = 2 requests on the wire. Locks in
        // the auto-authenticate behavior when the template cache is warm.
        #expect(callCount == 2)
        #expect(entries.count == 1)
        #expect(entries[0].title == "Test")
        #expect(entries[0].authors == ["Author One"])
        #expect(entries[0].identity.koboBookUUID == "u1")
        #expect(entries[0].format == .epub)
        #expect(entries[0].downloadURL.absoluteString == "https://cwa/download/1/kepub")
        #expect(entries[0].thumbnailURL?.absoluteString == "https://cwa/cov1/1200/1600/false/image.jpg")
    }

    // MARK: helpers
    private func makeBackend() -> KoboBackend {
        let http = HTTPClient(session: MockURLProtocol.session())
        let kc = KoboClient(
            baseURL: URL(string: "https://cwa/kobo/T")!,
            http: http,
            deviceID: "D"
        )
        return KoboBackend(client: kc, deviceID: "D", deviceName: "iPhone", imageURLTemplate: nil)
    }
}
