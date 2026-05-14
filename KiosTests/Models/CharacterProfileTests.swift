import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("CharacterProfile @Model", .serialized)
@MainActor
struct CharacterProfileTests {
    @Test("round-trip + bookID predicate")
    func roundTrip() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let profile = CharacterProfile(
            id: UUID(),
            bookID: bookID,
            canonicalName: "John Smith",
            allAliases: ["Smith", "Doctor"],
            synthesizedDescription: "A weary traveller who arrives at dusk.",
            earliestChapterIndex: 1,
            latestChapterIndex: 17
        )
        ctx.insert(profile)
        try ctx.save()

        let descriptor = FetchDescriptor<CharacterProfile>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let fetched = try ctx.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.allAliases.count == 2)
    }
}
