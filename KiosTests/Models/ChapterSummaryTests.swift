import Testing
@testable import Kios
import SwiftData
import Foundation
import Core

@Suite("ChapterSummary")
struct ChapterSummaryTests {
    @Test("makeID composes book, href, engine deterministically")
    func makeID() {
        let id = UUID()
        let composed = ChapterSummary.makeID(
            bookID: id,
            chapterHref: "ch1.xhtml",
            engine: .gemma4_e4b
        )
        #expect(composed == "\(id.uuidString)|ch1.xhtml|gemma4_e4b")
    }

    @Test("different engines produce different IDs for same chapter")
    func engineSeparation() {
        let id = UUID()
        let a = ChapterSummary.makeID(bookID: id, chapterHref: "ch1", engine: .gemma4_e4b)
        let b = ChapterSummary.makeID(bookID: id, chapterHref: "ch1", engine: .foundationModels)
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
            engine: AIEngine.gemma4_e4b.rawValue,
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
