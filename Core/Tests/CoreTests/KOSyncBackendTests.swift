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

    @Test func pushProgressEncodesKOSyncStringFromReadiumLocatorIntraProgression() async throws {
        let locator = #"{"href":"ch.xhtml","locations":{"progression":0.42}}"#
        let upload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: locator, percentage: 0.5)
        )
        #expect(upload.progress == "0:0.4200")
        #expect(upload.percentage == 0.5)
    }

    @Test func pushProgressFallsBackToZeroWhenLocatorJSONIsNil() async throws {
        let upload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: nil, percentage: 0.1)
        )
        #expect(upload.progress == "0:0.0000")
    }

    @Test func pushProgressFallsBackToZeroWhenLocatorJSONIsMalformed() async throws {
        let upload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: "not json", percentage: 0.1)
        )
        #expect(upload.progress == "0:0.0000")
    }

    @Test func pushProgressFallsBackToZeroWhenProgressionFieldIsMissing() async throws {
        let locator = #"{"href":"ch.xhtml","locations":{}}"#
        let upload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: locator, percentage: 0.1)
        )
        #expect(upload.progress == "0:0.0000")
    }

    @Test func pushProgressClampsProgressionToZeroOneRange() async throws {
        let highLocator = #"{"locations":{"progression":1.5}}"#
        let highUpload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: highLocator, percentage: 0.9)
        )
        #expect(highUpload.progress == "0:1.0000")

        let lowLocator = #"{"locations":{"progression":-0.2}}"#
        let lowUpload = try await capturePushedUpload(
            progress: makeProgress(locatorJSON: lowLocator, percentage: 0.1)
        )
        #expect(lowUpload.progress == "0:0.0000")
    }

    // MARK: helpers

    private func makeProgress(locatorJSON: String?, percentage: Double) -> CanonicalProgress {
        CanonicalProgress(
            percentage: percentage,
            locatorJSON: locatorJSON,
            timestamp: Date(timeIntervalSince1970: 1700000000),
            deviceID: "DEV",
            deviceName: "iPhone"
        )
    }

    /// Drives `pushProgress` through the mock URL protocol and decodes the
    /// `ProgressUpload` payload from the captured PUT body.
    private func capturePushedUpload(progress: CanonicalProgress) async throws -> ProgressUpload {
        let captured = LockedBox<Data>()
        MockURLProtocol.handler = { req in
            #expect(req.httpMethod == "PUT")
            #expect(req.url?.path == "/kosync/syncs/progress")
            captured.value = req.readBodyStream()
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (resp, Data("{}".utf8))
        }
        let backend = makeBackend()
        let id = BookIdentity(partialMD5: "abc123", koboBookUUID: nil)
        try await backend.pushProgress(progress, for: id)
        guard let data = captured.value else {
            Issue.record("no request body captured")
            return try JSONDecoder().decode(ProgressUpload.self, from: Data())
        }
        return try JSONDecoder().decode(ProgressUpload.self, from: data)
    }

    private final class LockedBox<T>: @unchecked Sendable {
        var value: T?
    }

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
