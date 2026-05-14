import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("CharacterMention @Model", .serialized)
@MainActor
struct CharacterMentionTests {
    @Test("round-trip + bookID predicate")
    func roundTrip() throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let mention = CharacterMention(
            id: UUID(),
            bookID: bookID,
            chapterIndex: 3,
            chapterHref: "OEBPS/ch3.xhtml",
            canonicalName: "John Smith",
            aliasesInChapter: ["Smith"],
            descriptionFromChapter: "Weary traveller.",
            significance: "major",
            quote: "Smith stepped off the train at dusk.",
            profileID: nil
        )
        ctx.insert(mention)
        try ctx.save()

        let descriptor = FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let fetched = try ctx.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.canonicalName == "John Smith")
        #expect(fetched.first?.profileID == nil)
    }
}
