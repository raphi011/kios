// KiosTests/Models/BookV2DefaultsTests.swift
import Testing
import Foundation
import SwiftData
@testable import Kios

@Suite("Book V2 defaults", .serialized)
@MainActor
struct BookV2DefaultsTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func newBookDefaultsToSyncedSource() throws {
        let ctx = try makeContext()
        let book = Book(
            serverID: "srv-1",
            serverIDProtocol: "kosync",
            title: "T",
            authors: ["A"],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false
        )
        ctx.insert(book)
        #expect(book.source == .synced)
        #expect(book.coverFilename == nil)
    }

    @Test func localBookHasNilCatalogFields() throws {
        let ctx = try makeContext()
        let book = Book(
            source: .local,
            title: "T",
            authors: ["A"],
            format: .epub
        )
        ctx.insert(book)
        #expect(book.source == .local)
        #expect(book.serverID == nil)
        #expect(book.serverIDProtocol == nil)
        #expect(book.acquisitionURL == nil)
        #expect(book.koboBookUUID == nil)
        #expect(book.thumbnailURL == nil)
        #expect(book.archived == false)
    }
}
