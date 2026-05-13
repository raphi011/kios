import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("MostRecentBookSelector")
struct MostRecentBookSelectorTests {
    @Test func picksMostRecentlyTouchedBook() throws {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)

        let older = makeBook(filename: "old.epub", addedAt: Date(timeIntervalSince1970: 100))
        let newer = makeBook(filename: "new.epub", addedAt: Date(timeIntervalSince1970: 200))
        context.insert(older)
        context.insert(newer)

        // Both have progress > 0 < 0.95.
        let p1 = ReadingProgress(
            bookID: older.id, locatorJSON: "{}", koSyncProgressString: nil,
            koboLocationSource: nil, koboLocationValue: nil,
            percentage: 0.3, updatedAt: .now, deviceID: "d",
            pendingUpload: false, pendingProtocol: nil
        )
        let p2 = ReadingProgress(
            bookID: newer.id, locatorJSON: "{}", koSyncProgressString: nil,
            koboLocationSource: nil, koboLocationValue: nil,
            percentage: 0.3, updatedAt: .now, deviceID: "d",
            pendingUpload: false, pendingProtocol: nil
        )
        context.insert(p1)
        context.insert(p2)

        // Sessions: `newer` touched more recently.
        context.insert(ReadingSession(
            id: UUID(), bookID: older.id,
            startedAt: Date(timeIntervalSince1970: 500),
            endedAt: Date(timeIntervalSince1970: 600),
            durationSeconds: 100, minPosition: 0, maxPosition: 1,
            pagesAdded: 1, endReason: "closed"
        ))
        context.insert(ReadingSession(
            id: UUID(), bookID: newer.id,
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1100),
            durationSeconds: 100, minPosition: 0, maxPosition: 1,
            pagesAdded: 1, endReason: "closed"
        ))
        try context.save()

        let picked = MostRecentBookSelector.pick(in: context)
        #expect(picked?.id == newer.id)
    }

    @Test func returnsNilWhenNoEligibleBooks() throws {
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        // No books inserted.
        #expect(MostRecentBookSelector.pick(in: context) == nil)
    }

    private func makeBook(filename: String, addedAt: Date) -> Book {
        Book(
            serverID: UUID().uuidString,
            serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false,
            filename: filename, addedAt: addedAt
        )
    }
}
