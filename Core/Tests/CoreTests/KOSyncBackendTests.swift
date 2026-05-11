import Testing
import Foundation
@testable import Core

@Suite("KOSyncBackend", .serialized)
struct KOSyncBackendTests {

    init() { MockURLProtocol.handler = nil }

    @Test func fetchProgressMapsToCanonical() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/kosync/syncs/progress/abc123")
            let body = #"""
            { "document":"abc123","progress":"5:0.4231","percentage":0.42,
              "device":"Other","device_id":"OTHER","timestamp":1700000000 }
            """#
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data(body.utf8))
        }
        let backend = makeBackend()
        let id = BookIdentity(partialMD5: "abc123", koboBookUUID: nil)
        let p = try await backend.fetchProgress(for: id)
        #expect(p?.percentage == 0.42)
        #expect(p?.deviceID == "OTHER")
        #expect(p?.deviceName == "Other")
        #expect(p?.timestamp == Date(timeIntervalSince1970: 1700000000))
    }

    @Test func fetchProgressMissingIdentityThrows() async throws {
        let backend = makeBackend()
        do {
            _ = try await backend.fetchProgress(
                for: BookIdentity(partialMD5: nil, koboBookUUID: nil)
            )
            Issue.record("expected throw")
        } catch BackendError.identityMissing(let field) {
            #expect(field == "partialMD5")
        }
    }

    // MARK: helpers
    private func makeBackend() -> KOSyncBackend {
        let http = HTTPClient(
            session: MockURLProtocol.session(),
            credentials: .init(username: "u", password: "p")
        )
        let kc = KOSyncClient(
            baseURL: URL(string: "https://cwa/kosync")!,
            http: http
        )
        return KOSyncBackend(client: kc, deviceID: "DEV", deviceName: "iPhone")
    }
}
