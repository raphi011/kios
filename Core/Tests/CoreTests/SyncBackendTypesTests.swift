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
}
