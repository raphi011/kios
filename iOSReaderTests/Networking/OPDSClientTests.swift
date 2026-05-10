import Testing
import Foundation
@testable import iOSReader
@testable import Core

@Suite("OPDSClient", .serialized)
struct OPDSClientTests {

    init() { MockURLProtocol.handler = nil }

    @Test func parsesCatalogEntries() async throws {
        let xml = try Self.loadFixture("calibre-web-opds")
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/atom+xml"]
            )!
            return (resp, xml)
        }
        let client = OPDSClient(
            http: HTTPClient(
                session: MockURLProtocol.session(),
                credentials: .init(username: "u", password: "p")
            )
        )
        let catalog = try await client.fetchCatalog(url: URL(string: "https://example/opds/")!)
        #expect(catalog.entries.count == 1)
        let entry = catalog.entries[0]
        #expect(entry.title == "Dune")
        #expect(entry.authors == ["Frank Herbert"])
        #expect(entry.format == .epub)
        #expect(entry.acquisitionURL.absoluteString == "https://example/dl/dune.epub")
    }

    private static func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "xml") else {
            throw NSError(domain: "fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing fixture \(name).xml in test bundle",
            ])
        }
        return try Data(contentsOf: url)
    }

    private final class BundleToken {}
}
