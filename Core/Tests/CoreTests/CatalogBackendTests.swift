import Testing
import Foundation
@testable import Core

struct CatalogBackendTests {
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
}
