import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("LibraryService — cascade delete", .serialized)
struct LibraryServiceCascadeDeleteTests {
    @Test("deleting a book removes its analysis rows")
    func cascadeAnalysisRows() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let book = Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub)
        ctx.insert(book)
        ctx.insert(BookAnalysis(bookID: bookID, engine: "gemma4_e4b", chaptersTotal: 5))
        ctx.insert(CharacterMention(
            id: UUID(), bookID: bookID, chapterIndex: 0, chapterHref: "h",
            canonicalName: "n", aliasesInChapter: [],
            descriptionFromChapter: "d", significance: "minor",
            quote: "q", profileID: nil
        ))
        ctx.insert(CharacterProfile(
            id: UUID(), bookID: bookID, canonicalName: "n",
            allAliases: [], synthesizedDescription: "d",
            earliestChapterIndex: 0, latestChapterIndex: 0
        ))
        ctx.insert(ChapterSummary(
            id: "\(bookID.uuidString)|h|gemma4_e4b",
            bookID: bookID, chapterHref: "h",
            engine: "gemma4_e4b", text: "chapter",
            createdAt: Date(), sourceHash: "hash"
        ))
        ctx.insert(BookSummary(bookID: bookID, engine: "gemma4_e4b", text: "book"))
        try ctx.save()

        let library = LibraryService(context: ctx)
        try library.delete(book: book)

        #expect(try ctx.fetch(FetchDescriptor<BookAnalysis>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<CharacterMention>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<CharacterProfile>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<ChapterSummary>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<BookSummary>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Book>()).isEmpty)
    }
}
