import Testing
import Foundation
import SwiftData
@testable import iOSReader
@testable import Core

@Suite("LibraryService")
@MainActor
struct LibraryServiceTests {

    final class MockOPDS: OPDSClientProtocol {
        var feed: OPDSFeed!
        // Allow chaining: pages returned in order, then nil for "no next".
        var pages: [OPDSFeed] = []
        var fetchCallCount = 0

        func fetchFeed(url: URL) async throws -> OPDSFeed {
            fetchCallCount += 1
            if !pages.isEmpty {
                return pages.removeFirst()
            }
            return feed
        }

        func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor {
            return OpenSearchDescriptor(templateURL: URL(string: "https://example.com/search?q={searchTerms}")!)
        }

        func invalidate(_ url: URL) async {}
        func invalidateAll() async {}
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private static func makeAcqEntry(
        serverID: String, title: String, authors: [String],
        acquisitionURL: URL, format: BookFormat
    ) -> OPDSFeed.Entry {
        let acq = Acquisition(href: acquisitionURL, mimeType: format == .epub ? "application/epub+zip" : "application/pdf", format: format)
        let entry = AcquisitionEntry(
            serverID: serverID,
            title: title,
            authors: authors,
            summary: nil,
            publishedAt: nil,
            acquisitions: [acq],
            thumbnailURL: nil,
            coverURL: nil
        )
        return .acquisition(entry)
    }

    @Test func upsertsAndProducesItems() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        opds.feed = OPDSFeed(
            title: "T",
            entries: [
                Self.makeAcqEntry(
                    serverID: "id1", title: "Dune", authors: ["FH"],
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil,
            searchDescriptorURL: nil
        )
        let service = LibraryService(
            opds: opds, context: context,
            rootURL: URL(string: "https://example/")!
        )
        try await service.refresh()
        #expect(service.items.count == 1)
        #expect(service.items[0].title == "Dune")
        #expect(service.items[0].state == .remote)
    }

    @Test func updatesExistingBookInsteadOfDuplicating() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        opds.feed = OPDSFeed(
            title: "T",
            entries: [
                Self.makeAcqEntry(
                    serverID: "id1", title: "Dune (rev 1)", authors: ["FH"],
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil,
            searchDescriptorURL: nil
        )
        let service = LibraryService(
            opds: opds, context: context,
            rootURL: URL(string: "https://example/")!
        )
        try await service.refresh()
        #expect(service.items.count == 1)
        #expect(service.items[0].title == "Dune (rev 1)")

        // Second refresh with updated title.
        opds.feed = OPDSFeed(
            title: "T",
            entries: [
                Self.makeAcqEntry(
                    serverID: "id1", title: "Dune (rev 2)", authors: ["FH"],
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil,
            searchDescriptorURL: nil
        )
        try await service.refresh()
        #expect(service.items.count == 1)            // still one row
        #expect(service.items[0].title == "Dune (rev 2)")
    }

    @Test func followsPaginationToCompletion() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        let page1 = OPDSFeed(
            title: "p1",
            entries: [
                Self.makeAcqEntry(
                    serverID: "a", title: "A", authors: [],
                    acquisitionURL: URL(string: "https://x/a.epub")!,
                    format: .epub
                )
            ],
            nextURL: URL(string: "https://example/opds/page2"),
            searchDescriptorURL: nil
        )
        let page2 = OPDSFeed(
            title: "p2",
            entries: [
                Self.makeAcqEntry(
                    serverID: "b", title: "B", authors: [],
                    acquisitionURL: URL(string: "https://x/b.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil,
            searchDescriptorURL: nil
        )
        opds.pages = [page1, page2]
        let service = LibraryService(
            opds: opds, context: context,
            rootURL: URL(string: "https://example/")!
        )
        try await service.refresh()
        #expect(opds.fetchCallCount == 2)
        #expect(Set(service.items.map(\.title)) == Set(["A", "B"]))
    }

    @Test func reflectsDownloadedStateAfterFlagsSet() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        opds.feed = OPDSFeed(
            title: "T",
            entries: [
                Self.makeAcqEntry(
                    serverID: "id1", title: "Dune", authors: [],
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil,
            searchDescriptorURL: nil
        )
        let service = LibraryService(
            opds: opds, context: context,
            rootURL: URL(string: "https://example/")!
        )
        try await service.refresh()
        #expect(service.items[0].state == .remote)

        // Mark as downloaded by mutating the persisted Book.
        let books = try context.fetch(FetchDescriptor<Book>())
        let book = try #require(books.first)
        book.fileURL = URL(fileURLWithPath: "/tmp/dune.epub")
        book.partialMD5 = "deadbeef"
        try context.save()

        // Trigger another refresh to rebuild items.
        try await service.refresh()
        if case .downloaded(let url, let md5) = service.items[0].state {
            #expect(url.path == "/tmp/dune.epub")
            #expect(md5 == "deadbeef")
        } else {
            Issue.record("expected .downloaded")
        }
    }
}
