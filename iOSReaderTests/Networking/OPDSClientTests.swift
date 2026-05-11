import Testing
import Foundation
@testable import iOSReader
@testable import Core

@Suite("OPDSClient", .serialized)
struct OPDSClientTests {

    init() { MockURLProtocol.handler = nil }

    // MARK: - Root navigation feed

    @Test func parsesRootNavigationFeed() async throws {
        let xml = try Self.loadFixture("cwa-opds-root")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://calibre.example/opds/")!
        )
        #expect(feed.entries.count == 4)
        for entry in feed.entries {
            if case .acquisition = entry { Issue.record("expected nav, got acquisition") }
        }
        #expect(feed.nextURL == nil)
        #expect(feed.searchDescriptorURL != nil)
        let titles = feed.entries.compactMap { e -> String? in
            if case .navigation(let n) = e { return n.title } else { return nil }
        }
        #expect(titles.contains("Recently added Books"))
    }

    // MARK: - Letter index

    @Test func parsesLetterIndexAndRelabelsZeroAsAll() async throws {
        let xml = try Self.loadFixture("cwa-opds-books-letter")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://calibre.example/opds/books")!
        )
        let navTitles = feed.entries.compactMap { e -> String? in
            if case .navigation(let n) = e { return n.title } else { return nil }
        }
        #expect(navTitles.first == "All")               // "00" relabeled (or already "All")
        #expect(navTitles.contains("A"))
        #expect(navTitles.contains("Z"))
        for entry in feed.entries {
            if case .acquisition = entry { Issue.record("expected nav-only feed") }
        }
    }

    // MARK: - Pagination

    @Test func parsesPublicationsWithPagination() async throws {
        let xml = try Self.loadFixture("cwa-opds-publications-p1")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://calibre.example/opds/books/letter/00")!
        )
        let acquisitions = feed.entries.compactMap { e -> AcquisitionEntry? in
            if case .acquisition(let a) = e { return a } else { return nil }
        }
        #expect(acquisitions.count == 60)
        #expect(feed.nextURL != nil)
        #expect(feed.nextURL!.absoluteString.contains("offset="))
        for entry in acquisitions {
            #expect(!entry.acquisitions.isEmpty)
            #expect(!entry.title.isEmpty)
        }
    }

    @Test func parsesTerminalPublicationsPage() async throws {
        let xml = try Self.loadFixture("cwa-opds-publications-p2")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://calibre.example/opds/books/letter/00?offset=240")!
        )
        #expect(feed.nextURL == nil)
    }

    // MARK: - Multi-format

    @Test func parsesMultipleAcquisitionFormats() async throws {
        let xml = try Self.loadFixture("cwa-opds-multi-format")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://example.com/opds/multiformat")!
        )
        guard case .acquisition(let entry) = feed.entries.first else {
            Issue.record("expected acquisition entry"); return
        }
        let formats = entry.acquisitions.map(\.format)
        #expect(formats.contains(.epub))
        #expect(formats.contains(.pdf))
        #expect(formats.contains(.cbz))
        #expect(entry.thumbnailURL != nil)
        #expect(entry.coverURL != nil)
    }

    // MARK: - Mixed feed

    @Test func parsesMixedNavAndAcquisitionEntries() async throws {
        let xml = try Self.loadFixture("cwa-opds-mixed")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://example.com/opds/mixed")!
        )
        let nav = feed.entries.compactMap { e -> NavigationEntry? in
            if case .navigation(let n) = e { return n } else { return nil }
        }
        let acq = feed.entries.compactMap { e -> AcquisitionEntry? in
            if case .acquisition(let a) = e { return a } else { return nil }
        }
        #expect(nav.count == 1)
        #expect(nav[0].title == "Sub-catalog A")
        #expect(acq.count == 1)
        #expect(acq[0].title == "Inline Book")
    }

    // MARK: - Search descriptor

    @Test func extractsSearchDescriptorURL() async throws {
        let xml = try Self.loadFixture("cwa-opds-with-search")
        Self.respond(with: xml)
        let client = Self.makeClient()
        let feed = try await client.fetchFeed(
            url: URL(string: "https://calibre.example/opds/")!
        )
        #expect(feed.searchDescriptorURL != nil)
        #expect(feed.searchDescriptorURL!.absoluteString.hasSuffix("/opds/osd"))
    }

    // MARK: - Cache

    @Test func cachesFeedWithinSession() async throws {
        let xml = try Self.loadFixture("cwa-opds-root")
        let counter = CounterBox()
        MockURLProtocol.handler = { req in
            counter.n += 1
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/atom+xml"]
            )!
            return (resp, xml)
        }
        let client = Self.makeClient()
        let url = URL(string: "https://calibre.example/opds/")!
        _ = try await client.fetchFeed(url: url)
        _ = try await client.fetchFeed(url: url)
        #expect(counter.n == 1)
    }

    @Test func invalidateForcesRefetch() async throws {
        let xml = try Self.loadFixture("cwa-opds-root")
        let counter = CounterBox()
        MockURLProtocol.handler = { req in
            counter.n += 1
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/atom+xml"]
            )!
            return (resp, xml)
        }
        let client = Self.makeClient()
        let url = URL(string: "https://calibre.example/opds/")!
        _ = try await client.fetchFeed(url: url)
        await client.invalidate(url)
        _ = try await client.fetchFeed(url: url)
        #expect(counter.n == 2)
    }

    // MARK: - Fixture loading helpers

    private static func makeClient() -> OPDSClient {
        OPDSClient(
            http: HTTPClient(
                session: MockURLProtocol.session(),
                credentials: .init(username: "u", password: "p")
            )
        )
    }

    private static func respond(with data: Data, contentType: String = "application/atom+xml") {
        MockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
            return (resp, data)
        }
    }

    private static func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "xml") else {
            throw NSError(domain: "fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing fixture \(name).xml",
            ])
        }
        return try Data(contentsOf: url)
    }

    private final class BundleToken {}

    /// Thread-safe counter for use in @Sendable closures within .serialized test suite.
    private final class CounterBox: @unchecked Sendable {
        var n = 0
    }
}
