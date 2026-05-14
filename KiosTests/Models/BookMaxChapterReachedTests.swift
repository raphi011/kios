import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("Book.maxChapterIndexReached", .serialized)
@MainActor
struct BookMaxChapterReachedTests {
    @Test("defaults to 0 on new book")
    func defaultsToZero() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let book = Book(source: .local, id: UUID(), title: "T", authors: ["A"], format: .epub)
        ctx.insert(book)
        try ctx.save()
        #expect(book.maxChapterIndexReached == 0)
    }

    @Test("persists across context refetch")
    func persists() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let book = Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub)
        ctx.insert(book)
        book.maxChapterIndexReached = 7
        try ctx.save()

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == bookID })
        let fetched = try ctx.fetch(descriptor).first
        #expect(fetched?.maxChapterIndexReached == 7)
    }
}
