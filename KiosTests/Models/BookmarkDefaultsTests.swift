import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("Bookmark defaults", .serialized)
@MainActor
struct BookmarkDefaultsTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 ChapterSummary.self, BookAnalysis.self, CharacterMention.self,
                 CharacterProfile.self, BookSummary.self, Bookmark.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func newBookmarkPersistsAllFields() throws {
        let ctx = try makeContext()
        let bookID = UUID()
        let bookmark = Bookmark(
            bookID: bookID,
            position: 42,
            locatorJSON: "{}",
            chapterTitle: "Chapter Two"
        )
        ctx.insert(bookmark)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Bookmark>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.bookID == bookID)
        #expect(fetched.first?.position == 42)
        #expect(fetched.first?.locatorJSON == "{}")
        #expect(fetched.first?.chapterTitle == "Chapter Two")
    }

    @Test func createdAtDefaultsToNow() throws {
        let ctx = try makeContext()
        let before = Date.now.addingTimeInterval(-1)
        let bookmark = Bookmark(
            bookID: UUID(),
            position: 1,
            locatorJSON: "{}",
            chapterTitle: ""
        )
        ctx.insert(bookmark)
        let after = Date.now.addingTimeInterval(1)
        #expect(bookmark.createdAt >= before)
        #expect(bookmark.createdAt <= after)
    }
}
