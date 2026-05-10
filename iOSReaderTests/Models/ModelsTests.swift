import Testing
import Foundation
import SwiftData
@testable import iOSReader

@Suite("SwiftData models")
struct ModelsTests {

    @Test func roundTripsBook() throws {
        let container = try ModelContainer(
            for: Book.self, LibraryServer.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let book = Book(
            serverID: "urn:uuid:abc",
            title: "Dune",
            authors: ["Frank Herbert"],
            opdsHref: URL(string: "https://example/opds/abc")!,
            acquisitionURL: URL(string: "https://example/dl/abc.epub")!,
            format: .epub
        )
        context.insert(book)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Dune")
    }
}
