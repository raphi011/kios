import Testing
@testable import Kios
import SwiftData
import Foundation
import Core

@Suite("ChapterSummary")
struct ChapterSummaryTests {
    @Test("makeID composes book, href, scope, engine deterministically")
    func makeID() {
        let id = UUID()
        let composed = ChapterSummary.makeID(
            bookID: id,
            chapterHref: "ch1.xhtml",
            scope: .readSoFar,
            engine: .gemma3_4b
        )
        #expect(composed == "\(id.uuidString)|ch1.xhtml|readSoFar|gemma3_4b")
    }

    @Test("different engines produce different IDs for same chapter")
    func engineSeparation() {
        let id = UUID()
        let a = ChapterSummary.makeID(bookID: id, chapterHref: "ch1", scope: .full, engine: .gemma3_4b)
        let b = ChapterSummary.makeID(bookID: id, chapterHref: "ch1", scope: .full, engine: .foundationModels)
        #expect(a != b)
    }

    @Test("ChapterSummary can be inserted and fetched")
    func roundTrip() async throws {
        let schema = Schema([ChapterSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let row = ChapterSummary(
            id: "test-id",
            bookID: UUID(),
            chapterHref: "ch1",
            scope: SummaryScope.full.rawValue,
            engine: AIEngine.gemma3_4b.rawValue,
            text: "Summary text.",
            createdAt: Date(),
            sourceHash: String(repeating: "0", count: 64)
        )
        ctx.insert(row)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ChapterSummary>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "Summary text.")
    }
}
