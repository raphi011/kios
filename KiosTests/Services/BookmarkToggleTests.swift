import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("BookmarkToggle", .serialized)
@MainActor
struct BookmarkToggleTests {
    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer.kiosInMemory())
    }

    @Test func insertsBookmarkWhenNotPresent() throws {
        let ctx = try makeContext()
        let book = UUID()

        BookmarkToggle.toggle(
            in: ctx,
            bookID: book,
            position: 10,
            locatorJSON: "L",
            chapterTitle: "C"
        )

        let all = try ctx.fetch(FetchDescriptor<Bookmark>())
        #expect(all.count == 1)
        #expect(all.first?.bookID == book)
        #expect(all.first?.position == 10)
        #expect(all.first?.locatorJSON == "L")
        #expect(all.first?.chapterTitle == "C")
    }

    @Test func deletesBookmarkWhenAlreadyPresentAtSamePosition() throws {
        let ctx = try makeContext()
        let book = UUID()

        BookmarkToggle.toggle(in: ctx, bookID: book, position: 7, locatorJSON: "L", chapterTitle: "C")
        BookmarkToggle.toggle(in: ctx, bookID: book, position: 7, locatorJSON: "L", chapterTitle: "C")

        let all = try ctx.fetch(FetchDescriptor<Bookmark>())
        #expect(all.isEmpty)
    }

    @Test func doesNotCollideAcrossBooks() throws {
        let ctx = try makeContext()
        let bookA = UUID()
        let bookB = UUID()

        BookmarkToggle.toggle(in: ctx, bookID: bookA, position: 5, locatorJSON: "A", chapterTitle: "CA")
        BookmarkToggle.toggle(in: ctx, bookID: bookB, position: 5, locatorJSON: "B", chapterTitle: "CB")

        let all = try ctx.fetch(FetchDescriptor<Bookmark>())
        #expect(all.count == 2)
        #expect(Set(all.map(\.bookID)) == [bookA, bookB])
    }

    @Test func doesNotCollideAcrossPositionsInSameBook() throws {
        let ctx = try makeContext()
        let book = UUID()

        BookmarkToggle.toggle(in: ctx, bookID: book, position: 5, locatorJSON: "L5", chapterTitle: "C")
        BookmarkToggle.toggle(in: ctx, bookID: book, position: 9, locatorJSON: "L9", chapterTitle: "C")

        let all = try ctx.fetch(FetchDescriptor<Bookmark>())
        #expect(all.count == 2)
        #expect(Set(all.map(\.position)) == [5, 9])
    }
}
