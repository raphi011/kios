import Testing
import Foundation
import SwiftData
@testable import iOSReader

@MainActor
@Suite("BookDetailView reconciliation")
struct BookDetailViewReconciliationTests {

    @Test func findsExistingBookByServerID() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let book = Book(
            serverID: "urn:cwa:book:42",
            title: "Persistent",
            authors: ["A"],
            opdsHref: URL(string: "https://e/h")!,
            acquisitionURL: URL(string: "https://e/a")!,
            format: .epub,
            fileURL: URL(fileURLWithPath: "/tmp/x.epub"),
            partialMD5: "abc"
        )
        ctx.insert(book)
        try ctx.save()

        let found = BookDetailView.findBook(serverID: "urn:cwa:book:42", context: ctx)
        #expect(found != nil)
        #expect(found?.fileURL == book.fileURL)
    }

    @Test func returnsNilWhenNoMatch() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        #expect(BookDetailView.findBook(serverID: "missing", context: ctx) == nil)
    }
}
