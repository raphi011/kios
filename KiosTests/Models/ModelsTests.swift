import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("SwiftData models")
struct ModelsTests {

    @Test func roundTripsBook() throws {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let book = Book(
            serverID: "urn:uuid:abc",
            serverIDProtocol: "kosync",
            title: "Dune",
            authors: ["Frank Herbert"],
            opdsHref: URL(string: "https://example/opds/abc")!,
            acquisitionURL: URL(string: "https://example/dl/abc.epub")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false
        )
        context.insert(book)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Book>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Dune")
    }

    @Test func bookDefaultsToUnfinished() throws {
        let book = Book(
            serverID: "s1",
            serverIDProtocol: "kosync",
            title: "t",
            authors: [],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://example.com/a")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false
        )
        #expect(book.finishedAt == nil)
        #expect(book.finishedManually == false)
    }
}
