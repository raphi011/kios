import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("BookSummary @Model", .serialized)
@MainActor
struct BookSummaryTests {
    @Test("round-trip + bookID predicate")
    func roundTrip() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let row = BookSummary(bookID: bookID, engine: "gemma4_e4b", text: "Whole-book synopsis.")
        ctx.insert(row)
        try ctx.save()

        let descriptor = FetchDescriptor<BookSummary>(predicate: #Predicate { $0.bookID == bookID })
        let fetched = try ctx.fetch(descriptor).first
        #expect(fetched?.text == "Whole-book synopsis.")
        #expect(fetched?.engine == "gemma4_e4b")
    }
}
