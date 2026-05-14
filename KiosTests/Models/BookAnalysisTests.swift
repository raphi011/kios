import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("BookAnalysis @Model", .serialized)
@MainActor
struct BookAnalysisTests {
    @Test("round-trip through ModelContainer")
    func roundTrip() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let row = BookAnalysis(
            bookID: bookID,
            engine: "gemma4_e4b",
            chaptersTotal: 12
        )
        ctx.insert(row)
        try ctx.save()

        let descriptor = FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let fetched = try ctx.fetch(descriptor).first
        #expect(fetched?.status == "in_progress")
        #expect(fetched?.chaptersTotal == 12)
        #expect(fetched?.chaptersCompleted == 0)
        #expect(fetched?.schemaVersion == BookAnalysis.currentSchemaVersion)
    }

    @Test("currentSchemaVersion is 1 at v1")
    func schemaVersionIsOne() {
        #expect(BookAnalysis.currentSchemaVersion == 1)
    }
}
