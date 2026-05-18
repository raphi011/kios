import Testing
import Foundation
import SwiftData
@testable import Kios

@MainActor
@Suite("Migrations.applyWatermarkModelWipeIfNeeded")
struct MigrationsWatermarkWipeTests {

    @Test("wipe deletes existing ReadingSession rows when flag is false")
    func wipeAppliesOnce() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.removeObject(forKey: Migrations.watermarkWipeFlagKey)

        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let src = testSource(into: context)
        let book = Book(
            source: src,
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

        Migrations.applyWatermarkModelWipeIfNeeded(context: context, defaults: defaults)

        let remaining = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(remaining.isEmpty)
        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(defaults.bool(forKey: Migrations.watermarkWipeFlagKey))
    }

    @Test("wipe is idempotent when flag is true")
    func wipeIdempotent() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: Migrations.watermarkWipeFlagKey)

        let container = try ModelContainer.kiosInMemory()
        let context = ModelContext(container)
        let src = testSource(into: context)
        let book = Book(
            source: src,
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

        Migrations.applyWatermarkModelWipeIfNeeded(context: context, defaults: defaults)

        let remaining = try context.fetch(FetchDescriptor<ReadingSession>())
        #expect(remaining.count == 1)
    }
}
