import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("ModelContainer.kios factory")
struct ModelContainerFactoryTests {
    @Test func inMemoryContainerHostsAllModels() throws {
        // Sanity: every model the app uses can be inserted into the
        // factory-built (in-memory variant) container.
        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)

        let src = testSource(into: context)
        let book = Book(
            source: src,
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false
        )
        let session = ReadingSession(
            id: UUID(), bookID: book.id,
            startedAt: .now, endedAt: .now,
            durationSeconds: 0,
            pagesAdded: 0, endReason: "closed"
        )
        context.insert(book)
        context.insert(session)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Book>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ReadingSession>()).count == 1)
    }
}
