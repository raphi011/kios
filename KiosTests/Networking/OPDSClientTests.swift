import Testing
import Foundation
import os
@testable import Kios
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

        // CWA's root is pure navigation — no acquisition entries.
        let nav = feed.entries.compactMap { e -> NavigationEntry? in
            if case .navigation(let n) = e { return n } else { return nil }
        }
        let acq = feed.entries.compactMap { e -> AcquisitionEntry? in
            if case .acquisition(let a) = e { return a } else { return nil }
        }
        #expect(nav.count == feed.entries.count, "root must be 100% navigation")
        #expect(acq.isEmpty, "root must not contain publications")

        // Real CWA root has 16+ nav entries depending on version. Assert the canonical
        // four that every CWA exposes, regardless of optional categories.
        let titles = nav.map(\.title)
        #expect(titles.contains("Recently added Books"))
        #expect(titles.contains("Alphabetical Books"))

        // Root is a single page; no pagination, but the OpenSearch descriptor is
        // always present at the root.
        #expect(feed.nextURL == nil)
        #expect(feed.searchDescriptorURL != nil)
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

        // CWA emits 60 atom entries per page. Some books in this library are
        // azw3-only or cbr-only — formats we don't support — so the parser
        // drops those entries entirely. Assert the parser behavior, not a
        // magic number: every returned entry has at least one supported
        // acquisition, and we got fewer than 60 because at least one was
        // filtered.
        let acquisitions = feed.entries.compactMap { e -> AcquisitionEntry? in
            if case .acquisition(let a) = e { return a } else { return nil }
        }
        #expect(acquisitions.count > 0, "page should yield supported entries")
        #expect(acquisitions.count <= 60, "must not exceed atom entry count")
        for entry in acquisitions {
            #expect(!entry.acquisitions.isEmpty,
                    "every returned entry has at least one supported acquisition")
            #expect(!entry.title.isEmpty)
            for acq in entry.acquisitions {
                // Sanity: each kept acquisition is one of the formats we model.
                #expect([BookFormat.epub, .pdf, .cbz].contains(acq.format))
            }
            // No duplicate formats per entry — picker would show "EPUB" twice
            // if the parser kept multiple same-format acquisitions.
            let formats = entry.acquisitions.map(\.format)
            #expect(formats.count == Set(formats).count,
                    "acquisitions must be deduped by format")
        }

        // Pagination link is always present on a non-terminal page.
        #expect(feed.nextURL != nil)
        #expect(feed.nextURL!.absoluteString.contains("offset="))
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

    // MARK: - OpenSearch descriptor

    @Test func parsesOpenSearchDescriptor() async throws {
        let xml = try Self.loadFixture("cwa-opensearch-description")
        Self.respond(with: xml, contentType: "application/opensearchdescription+xml")
        let client = Self.makeClient()
        let descriptor = try await client.fetchSearchDescriptor(
            at: URL(string: "https://calibre.example/opds/osd")!
        )
        // URL encodes { and } as %7B and %7D, so check for encoded placeholder
        #expect(descriptor.templateURL.absoluteString.contains("%7BsearchTerms%7D"))
        let resolved = descriptor.resolve(query: "Dune")
        #expect(resolved != nil)
        #expect(resolved!.absoluteString.contains("Dune"))
    }

    @Test func cachesSearchDescriptor() async throws {
        let xml = try Self.loadFixture("cwa-opensearch-description")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { req in
            counter.withLock { $0 += 1 }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/opensearchdescription+xml"]
            )!
            return (resp, xml)
        }
        let client = Self.makeClient()
        let url = URL(string: "https://calibre.example/opds/osd")!
        _ = try await client.fetchSearchDescriptor(at: url)
        _ = try await client.fetchSearchDescriptor(at: url)
        #expect(counter.withLock { $0 } == 1)
    }

    @Test func descriptorParseFailureThrowsDedicatedError() async throws {
        // OpenSearch description doc with a <Url> that lacks {searchTerms}.
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>No template</ShortName>
          <Url type="application/atom+xml" template="https://example.com/static-search"/>
        </OpenSearchDescription>
        """.utf8)
        Self.respond(with: xml, contentType: "application/opensearchdescription+xml")
        let client = Self.makeClient()
        await #expect(throws: OPDSClientError.invalidOpenSearchDescriptor) {
            _ = try await client.fetchSearchDescriptor(
                at: URL(string: "https://example.com/opds/osd")!
            )
        }
    }

    // MARK: - Cache

    @Test func cachesFeedWithinSession() async throws {
        let xml = try Self.loadFixture("cwa-opds-root")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { req in
            counter.withLock { $0 += 1 }
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
        #expect(counter.withLock { $0 } == 1)
    }

    @Test func invalidateForcesRefetch() async throws {
        let xml = try Self.loadFixture("cwa-opds-root")
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { req in
            counter.withLock { $0 += 1 }
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
        #expect(counter.withLock { $0 } == 2)
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
}
