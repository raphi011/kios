import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("ReadingSession model")
struct ReadingSessionTests {
    @Test func roundTripsThroughInMemoryContainer() throws {
        let container = try ModelContainer(
            for: ReadingSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let bookID = UUID()
        let session = ReadingSession(
            id: UUID(),
            bookID: bookID,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            endedAt: Date(timeIntervalSince1970: 1_000_300),
            durationSeconds: 300,
            minPosition: 10,
            maxPosition: 14,
            pagesAdded: 4,
            endReason: "closed"
        )
        context.insert(session)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(rows.count == 1)
        #expect(rows[0].bookID == bookID)
        #expect(rows[0].durationSeconds == 300)
        #expect(rows[0].pagesAdded == 4)
        #expect(rows[0].endReason == "closed")
    }
}
