import Testing
import Foundation
@testable import iOSReader
@testable import Core

@Suite("OPDSCatalogAdapter", .serialized)
struct OPDSCatalogAdapterTests {

    // MARK: - Filtering

    @Test func listLibraryFiltersOutNavigationEntries() async throws {
        let stub = StubOPDSClient(feeds: [
            url("https://example.com/opds/"): OPDSFeed(
                title: "root",
                entries: [
                    .navigation(NavigationEntry(
                        id: "nav-1", title: "Subsection",
                        summary: nil, href: url("https://example.com/opds/sub")
                    )),
                    .acquisition(Self.epubEntry(serverID: "book-1", title: "Book One")),
                ],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: url("https://example.com/opds/"))

        let entries = try await adapter.listLibrary()

        #expect(entries.count == 1)
        #expect(entries[0].serverID == "book-1")
        #expect(entries[0].title == "Book One")
    }

    // MARK: - Pagination

    @Test func listLibraryPaginatesViaNextURL() async throws {
        let page1 = url("https://example.com/opds/?offset=0")
        let page2 = url("https://example.com/opds/?offset=60")
        let page3 = url("https://example.com/opds/?offset=120")
        let stub = StubOPDSClient(feeds: [
            page1: OPDSFeed(
                title: "p1",
                entries: [.acquisition(Self.epubEntry(serverID: "book-1", title: "B1"))],
                nextURL: page2,
                searchDescriptorURL: nil
            ),
            page2: OPDSFeed(
                title: "p2",
                entries: [.acquisition(Self.epubEntry(serverID: "book-2", title: "B2"))],
                nextURL: page3,
                searchDescriptorURL: nil
            ),
            page3: OPDSFeed(
                title: "p3",
                entries: [.acquisition(Self.epubEntry(serverID: "book-3", title: "B3"))],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: page1)

        let entries = try await adapter.listLibrary()

        #expect(entries.map(\.serverID) == ["book-1", "book-2", "book-3"])
    }

    @Test func listLibraryThrowsOnExcessivePagination() async throws {
        // Synthesise an infinite-loop feed: every page's nextURL points to
        // a fresh URL whose response also has a fresh nextURL. The adapter
        // must bail at `maxFeedPages` rather than loop forever.
        let stub = InfinitePagesStubOPDSClient()
        let adapter = OPDSCatalogAdapter(
            client: stub,
            rootURL: url("https://example.com/opds/?page=0")
        )

        await #expect(throws: OPDSCatalogAdapterError.feedPaginationOverflow) {
            _ = try await adapter.listLibrary()
        }
    }

    // MARK: - Format preference

    @Test func listLibraryPrefersEPUBFormat() async throws {
        let epubURL = url("https://example.com/dl/multi.epub")
        let pdfURL = url("https://example.com/dl/multi.pdf")
        let entry = AcquisitionEntry(
            serverID: "multi",
            title: "Multi Format",
            authors: ["A"],
            summary: nil,
            publishedAt: nil,
            acquisitions: [
                Acquisition(href: pdfURL, mimeType: "application/pdf", format: .pdf),
                Acquisition(href: epubURL, mimeType: "application/epub+zip", format: .epub),
            ],
            thumbnailURL: nil,
            coverURL: nil
        )
        let stub = StubOPDSClient(feeds: [
            url("https://example.com/opds/"): OPDSFeed(
                title: "feed",
                entries: [.acquisition(entry)],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: url("https://example.com/opds/"))

        let entries = try await adapter.listLibrary()

        #expect(entries.count == 1)
        #expect(entries[0].format == .epub)
        #expect(entries[0].downloadURL == epubURL)
    }

    @Test func listLibraryFallsBackToFirstFormatWhenNoEPUB() async throws {
        let pdfURL = url("https://example.com/dl/only.pdf")
        let cbzURL = url("https://example.com/dl/only.cbz")
        let entry = AcquisitionEntry(
            serverID: "no-epub",
            title: "PDF Only",
            authors: ["A"],
            summary: nil,
            publishedAt: nil,
            acquisitions: [
                Acquisition(href: pdfURL, mimeType: "application/pdf", format: .pdf),
                Acquisition(href: cbzURL, mimeType: "application/x-cbz", format: .cbz),
            ],
            thumbnailURL: nil,
            coverURL: nil
        )
        let stub = StubOPDSClient(feeds: [
            url("https://example.com/opds/"): OPDSFeed(
                title: "feed",
                entries: [.acquisition(entry)],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: url("https://example.com/opds/"))

        let entries = try await adapter.listLibrary()

        #expect(entries.count == 1)
        #expect(entries[0].format == .pdf)
        #expect(entries[0].downloadURL == pdfURL)
    }

    // MARK: - Defensive

    @Test func listLibrarySkipsAcquisitionEntriesWithNoAcquisitions() async throws {
        // The OPDS parser upstream already drops entries with zero supported
        // acquisitions, but the adapter must remain defensive: an empty
        // acquisitions array yields no CatalogEntry rather than a crash.
        let emptyEntry = AcquisitionEntry(
            serverID: "empty",
            title: "Nothing to download",
            authors: [],
            summary: nil,
            publishedAt: nil,
            acquisitions: [],
            thumbnailURL: nil,
            coverURL: nil
        )
        let goodEntry = Self.epubEntry(serverID: "good", title: "Good")
        let stub = StubOPDSClient(feeds: [
            url("https://example.com/opds/"): OPDSFeed(
                title: "feed",
                entries: [.acquisition(emptyEntry), .acquisition(goodEntry)],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: url("https://example.com/opds/"))

        let entries = try await adapter.listLibrary()

        #expect(entries.map(\.serverID) == ["good"])
    }

    // MARK: - Resolve

    @Test func resolveDownloadReturnsEntryURL() async throws {
        let downloadURL = url("https://example.com/dl/book.epub")
        let entry = CatalogEntry(
            serverID: "id",
            title: "T",
            authors: ["A"],
            identity: BookIdentity(),
            downloadURL: downloadURL,
            format: .epub,
            thumbnailURL: nil
        )
        let adapter = OPDSCatalogAdapter(
            client: StubOPDSClient(feeds: [:]),
            rootURL: url("https://example.com/opds/")
        )

        let resolved = try await adapter.resolveDownload(for: entry)

        #expect(resolved == downloadURL)
    }

    // MARK: - Identity

    @Test func listLibraryProducesIdentityWithNoMD5OrUUID() async throws {
        let stub = StubOPDSClient(feeds: [
            url("https://example.com/opds/"): OPDSFeed(
                title: "feed",
                entries: [.acquisition(Self.epubEntry(serverID: "id-1", title: "T"))],
                nextURL: nil,
                searchDescriptorURL: nil
            ),
        ])
        let adapter = OPDSCatalogAdapter(client: stub, rootURL: url("https://example.com/opds/"))

        let entries = try await adapter.listLibrary()

        #expect(entries.count == 1)
        #expect(entries[0].identity.partialMD5 == nil)
        #expect(entries[0].identity.koboBookUUID == nil)
    }

    // MARK: - Helpers

    private func url(_ s: String) -> URL { URL(string: s)! }

    private static func epubEntry(serverID: String, title: String) -> AcquisitionEntry {
        AcquisitionEntry(
            serverID: serverID,
            title: title,
            authors: ["Author"],
            summary: nil,
            publishedAt: nil,
            acquisitions: [Acquisition(
                href: URL(string: "https://example.com/dl/\(serverID).epub")!,
                mimeType: "application/epub+zip",
                format: .epub
            )],
            thumbnailURL: URL(string: "https://example.com/thumb/\(serverID).jpg"),
            coverURL: nil
        )
    }
}

// MARK: - Stub clients

/// Map-backed stub: `fetchFeed(url:)` returns whatever `feeds[url]` says,
/// or throws `OPDSClientError.notAFeed` if the URL isn't registered.
private final class StubOPDSClient: OPDSClientProtocol, @unchecked Sendable {
    let feeds: [URL: OPDSFeed]

    init(feeds: [URL: OPDSFeed]) { self.feeds = feeds }

    func fetchFeed(url: URL) async throws -> OPDSFeed {
        guard let feed = feeds[url] else { throw OPDSClientError.notAFeed }
        return feed
    }

    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor {
        throw OPDSClientError.invalidOpenSearchDescriptor
    }

    func invalidate(_ url: URL) async {}
    func invalidateAll() async {}
}

/// Synthesises a feed for every URL, each pointing at a fresh next page —
/// the only termination condition is `OPDSCatalogAdapter.maxFeedPages`.
private final class InfinitePagesStubOPDSClient: OPDSClientProtocol, @unchecked Sendable {
    func fetchFeed(url: URL) async throws -> OPDSFeed {
        // Bump the page counter in the query string so every call returns
        // a fresh URL and the adapter never sees a duplicate (which a real
        // bounded loop check would catch independently).
        let next = URL(string: "https://example.com/opds/?page=\(UUID().uuidString)")!
        return OPDSFeed(title: "infinite", entries: [], nextURL: next, searchDescriptorURL: nil)
    }

    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor {
        throw OPDSClientError.invalidOpenSearchDescriptor
    }

    func invalidate(_ url: URL) async {}
    func invalidateAll() async {}
}
