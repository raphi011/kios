import Testing
import Foundation
@testable import Core

struct SyncBackendTypesTests {
    @Test func bookIdentityEquatable() {
        let a = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
        let b = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
        let c = BookIdentity(partialMD5: nil, koboBookUUID: "xyz")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func canonicalProgressRoundTrip() {
        let p = CanonicalProgress(
            percentage: 0.42,
            locatorJSON: #"{"href":"a"}"#,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "dev",
            deviceName: "iPhone"
        )
        #expect(p.percentage == 0.42)
        #expect(p.locatorJSON == #"{"href":"a"}"#)
    }

    @Test func syncBackendProtocolCallable() async throws {
        let backend: any SyncBackend = FakeSyncBackend()
        try await backend.authenticate()
        let id = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
        let progress = try await backend.fetchProgress(for: id)
        #expect(progress == nil)
    }
}

private struct FakeSyncBackend: SyncBackend {
    func authenticate() async throws {}
    func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? { nil }
    func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {}
}
