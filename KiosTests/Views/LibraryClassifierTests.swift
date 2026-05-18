import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("LibraryClassifier")
struct LibraryClassifierTests {

    /// Builds a minimal in-memory Book wired to a fresh local source.
    /// Each test calls this per book so identity is stable across asserts.
    private func makeBook(
        title: String,
        filename: String? = "book.epub",
        finishedAt: Date? = nil,
        into context: ModelContext
    ) -> Book {
        let source = testSource(into: context)
        let book = Book(
            source: source,
            title: title, authors: ["A"],
            format: .epub, filename: filename, finishedAt: finishedAt
        )
        context.insert(book)
        return book
    }

    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.kiosInMemory())
    }

    // MARK: - reading

    @Test("reading: progress strictly between 0 and 1, downloaded, not finished")
    func readingMatchesMidProgress() throws {
        let context = try ctx()
        let inProgress = makeBook(title: "Reading", into: context)
        let unstarted = makeBook(title: "Unstarted", into: context)
        let catalogOnly = makeBook(title: "CatalogOnly", filename: nil, into: context)
        let finished = makeBook(title: "Finished", finishedAt: .now, into: context)
        let progress = [
            inProgress.id: 0.5,
            unstarted.id: 0.0,
            catalogOnly.id: 0.5,    // catalog-only with progress shouldn't appear
            finished.id: 0.9,
        ]

        let result = LibraryClassifier.reading(
            [inProgress, unstarted, catalogOnly, finished],
            progressByBookID: progress
        )

        #expect(result.map(\.title) == ["Reading"])
    }

    @Test("reading: progress at exactly 1.0 is NOT reading (it's finished-by-watermark)")
    func readingExcludesFullProgress() throws {
        let context = try ctx()
        let done = makeBook(title: "Done", into: context)
        let result = LibraryClassifier.reading([done], progressByBookID: [done.id: 1.0])
        #expect(result.isEmpty)
    }

    // MARK: - unread

    @Test("unread: progress == 0 OR catalog-only, not finished")
    func unreadIncludesUnstartedAndCatalogOnly() throws {
        let context = try ctx()
        let unstarted = makeBook(title: "Unstarted", into: context)
        let catalogOnly = makeBook(title: "Catalog", filename: nil, into: context)
        let reading = makeBook(title: "Reading", into: context)
        let finished = makeBook(title: "Finished", finishedAt: .now, into: context)
        let progress = [
            unstarted.id: 0.0,
            // catalogOnly: missing from dict — defaults to 0
            reading.id: 0.5,
            finished.id: 0.0,    // even at 0 progress, finishedAt wins
        ]

        let result = LibraryClassifier.unread(
            [unstarted, catalogOnly, reading, finished],
            progressByBookID: progress
        )

        #expect(Set(result.map(\.title)) == Set(["Unstarted", "Catalog"]))
    }

    // MARK: - finished

    @Test("finished: only books with a finishedAt timestamp")
    func finishedSelectsByFinishedAt() throws {
        let context = try ctx()
        let f1 = makeBook(title: "F1", finishedAt: .now, into: context)
        let f2 = makeBook(title: "F2", finishedAt: .distantPast, into: context)
        let reading = makeBook(title: "Reading", into: context)
        let unstarted = makeBook(title: "Unstarted", into: context)

        let result = LibraryClassifier.finished([f1, f2, reading, unstarted])
        #expect(Set(result.map(\.title)) == Set(["F1", "F2"]))
    }

    @Test("classifiers are disjoint for any single book")
    func bucketsAreDisjoint() throws {
        let context = try ctx()
        let books = [
            makeBook(title: "InProgress", into: context),                    // reading
            makeBook(title: "Unstarted", into: context),                     // unread
            makeBook(title: "Catalog", filename: nil, into: context),        // unread
            makeBook(title: "Finished", finishedAt: .now, into: context),    // finished
        ]
        let progress = [books[0].id: 0.5]   // others default to 0

        let r = Set(LibraryClassifier.reading(books, progressByBookID: progress).map(\.id))
        let u = Set(LibraryClassifier.unread(books, progressByBookID: progress).map(\.id))
        let f = Set(LibraryClassifier.finished(books).map(\.id))

        #expect(r.isDisjoint(with: u))
        #expect(r.isDisjoint(with: f))
        #expect(u.isDisjoint(with: f))
    }
}
