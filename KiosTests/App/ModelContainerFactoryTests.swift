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

        let book = Book(
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

    @Test("wipe deletes existing ReadingSession rows when flag is false")
    func wipeAppliesOnce() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.removeObject(forKey: ModelContainerFactory.watermarkWipeFlagKey)

        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false, filename: nil
        )
        context.insert(book)
        let session = ReadingSession(
            id: UUID(), bookID: book.id,
            startedAt: Date(), endedAt: Date(),
            durationSeconds: 60, pagesAdded: 5, endReason: "closed"
        )
        context.insert(session)
        try context.save()

        ModelContainerFactory.applyWatermarkModelWipeIfNeeded(context: context, defaults: defaults)

        let remaining = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(remaining.isEmpty)
        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(defaults.bool(forKey: ModelContainerFactory.watermarkWipeFlagKey))
    }

    @Test("wipe is idempotent when flag is true")
    func wipeIdempotent() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: ModelContainerFactory.watermarkWipeFlagKey)

        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let book = Book(
            serverID: "s", serverIDProtocol: "kosync",
            title: "t", authors: [], opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub, koboBookUUID: nil, archived: false, filename: nil
        )
        context.insert(book)
        let session = ReadingSession(
            id: UUID(), bookID: book.id,
            startedAt: Date(), endedAt: Date(),
            durationSeconds: 60, pagesAdded: 5, endReason: "closed"
        )
        context.insert(session)
        try context.save()

        ModelContainerFactory.applyWatermarkModelWipeIfNeeded(context: context, defaults: defaults)

        let remaining = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(remaining.count == 1)
    }
}
