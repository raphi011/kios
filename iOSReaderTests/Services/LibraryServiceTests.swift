import Testing
import Foundation
import SwiftData
@testable import iOSReader

@Suite("LibraryService")
@MainActor
struct LibraryServiceTests {

    final class MockOPDS: OPDSClientProtocol {
        var catalog: OPDSCatalog!
        // Allow chaining: pages returned in order, then nil for "no next".
        var pages: [OPDSCatalog] = []
        var fetchCallCount = 0

        func fetchCatalog(url: URL) async throws -> OPDSCatalog {
            fetchCallCount += 1
            if !pages.isEmpty {
                return pages.removeFirst()
            }
            return catalog
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Book.self, LibraryServer.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func upsertsAndProducesItems() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        opds.catalog = OPDSCatalog(
            title: "T",
            entries: [
                OPDSEntry(
                    serverID: "id1", title: "Dune", authors: ["FH"],
                    detailURL: nil,
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil
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
        opds.catalog = OPDSCatalog(
            title: "T",
            entries: [
                OPDSEntry(
                    serverID: "id1", title: "Dune (rev 1)", authors: ["FH"],
                    detailURL: nil,
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil
        )
        let service = LibraryService(
            opds: opds, context: context,
            rootURL: URL(string: "https://example/")!
        )
        try await service.refresh()
        #expect(service.items.count == 1)
        #expect(service.items[0].title == "Dune (rev 1)")

        // Second refresh with updated title.
        opds.catalog = OPDSCatalog(
            title: "T",
            entries: [
                OPDSEntry(
                    serverID: "id1", title: "Dune (rev 2)", authors: ["FH"],
                    detailURL: nil,
                    acquisitionURL: URL(string: "https://x/dune.epub")!,
                    format: .epub
                )
            ],
            nextURL: nil
        )
        try await service.refresh()
        #expect(service.items.count == 1)            // still one row
        #expect(service.items[0].title == "Dune (rev 2)")
    }

    @Test func followsPaginationToCompletion() async throws {
        let context = try makeContext()
        let opds = MockOPDS()
        let page1 = OPDSCatalog(
            title: "p1",
            entries: [
                OPDSEntry(serverID: "a", title: "A", authors: [],
                          detailURL: nil,
                          acquisitionURL: URL(string: "https://x/a.epub")!,
                          format: .epub)
            ],
            nextURL: URL(string: "https://example/opds/page2")
        )
        let page2 = OPDSCatalog(
            title: "p2",
            entries: [
                OPDSEntry(serverID: "b", title: "B", authors: [],
                          detailURL: nil,
                          acquisitionURL: URL(string: "https://x/b.epub")!,
                          format: .epub)
            ],
            nextURL: nil
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
        opds.catalog = OPDSCatalog(
            title: "T",
            entries: [
                OPDSEntry(serverID: "id1", title: "Dune", authors: [],
                          detailURL: nil,
                          acquisitionURL: URL(string: "https://x/dune.epub")!,
                          format: .epub)
            ],
            nextURL: nil
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
