import Testing
import Foundation
import SwiftData
@testable import iOSReader

@MainActor
@Suite("BookActions")
struct BookActionsTests {

    @Test func findsExistingBookByServerIDAndFormat() throws {
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
            filename: "x.epub",
            partialMD5: "abc"
        )
        ctx.insert(book)
        try ctx.save()

        let found = BookActions.findBook(serverID: "urn:cwa:book:42",
                                         format: .epub, context: ctx)
        #expect(found != nil)
        #expect(found?.fileURL == book.fileURL)
    }

    @Test func returnsNilWhenNoMatch() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        #expect(BookActions.findBook(serverID: "missing",
                                     format: .epub, context: ctx) == nil)
    }

    @Test func doesNotFindWrongFormat() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let book = Book(
            serverID: "urn:cwa:book:99",
            title: "PDF Book",
            authors: [],
            opdsHref: URL(string: "https://e/h")!,
            acquisitionURL: URL(string: "https://e/a")!,
            format: .pdf
        )
        ctx.insert(book)
        try ctx.save()

        // Should not find when querying a different format
        let found = BookActions.findBook(serverID: "urn:cwa:book:99",
                                         format: .epub, context: ctx)
        #expect(found == nil)
    }

    @Test func findAllBooksReturnsBothFormats() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let epubBook = Book(
            serverID: "urn:cwa:book:7",
            title: "Dual Format",
            authors: ["B"],
            opdsHref: URL(string: "https://e/h")!,
            acquisitionURL: URL(string: "https://e/a")!,
            format: .epub,
            filename: "x.epub"
        )
        let pdfBook = Book(
            serverID: "urn:cwa:book:7",
            title: "Dual Format",
            authors: ["B"],
            opdsHref: URL(string: "https://e/h")!,
            acquisitionURL: URL(string: "https://e/b")!,
            format: .pdf,
            filename: "x.pdf"
        )
        ctx.insert(epubBook)
        ctx.insert(pdfBook)
        try ctx.save()

        let all = BookActions.findAllBooks(serverID: "urn:cwa:book:7", context: ctx)
        #expect(all.count == 2)
        let formats = Set(all.map(\.format))
        #expect(formats == [.epub, .pdf])
    }

    @Test func upsertCreatesNewRowPerFormat() throws {
        let container = try ModelContainer(
            for: Book.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let serverID = "urn:cwa:book:100"
        let entry = AcquisitionEntry(
            serverID: serverID,
            title: "Multi",
            authors: ["C"],
            summary: nil,
            publishedAt: nil,
            acquisitions: [
                Acquisition(href: URL(string: "https://e/epub")!, mimeType: "", format: .epub),
                Acquisition(href: URL(string: "https://e/pdf")!,  mimeType: "", format: .pdf)
            ],
            thumbnailURL: nil,
            coverURL: nil
        )

        let epubAcq = entry.acquisitions[0]
        let pdfAcq  = entry.acquisitions[1]

        _ = BookActions.upsertBook(entry: entry, chosen: epubAcq, context: ctx)
        _ = BookActions.upsertBook(entry: entry, chosen: pdfAcq,  context: ctx)

        let all = BookActions.findAllBooks(serverID: serverID, context: ctx)
        #expect(all.count == 2)
    }
}
