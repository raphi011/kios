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
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self, Source.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func newBookHasSource() throws {
        let ctx = try makeContext()
        let src = testSource(into: ctx)
        let book = Book(
            source: src,
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
        #expect(book.source === src)
        #expect(book.coverFilename == nil)
    }

    @Test("freshly-initialized Book has furthestLinearPosition == 0")
    func furthestLinearPositionDefaultsToZero() throws {
        let ctx = try makeContext()
        let src = testSource(into: ctx)
        let book = Book(
            source: src,
            serverID: "s",
            serverIDProtocol: "kosync",
            title: "t",
            authors: [],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            filename: nil
        )
        ctx.insert(book)
        #expect(book.furthestLinearPosition == 0)
    }

    @Test("freshly-initialized Book has totalPositions == 0")
    func totalPositionsDefaultsToZero() throws {
        let ctx = try makeContext()
        let src = testSource(into: ctx)
        let book = Book(
            source: src,
            serverID: "s",
            serverIDProtocol: "kosync",
            title: "t",
            authors: [],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://e.com/a")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            filename: nil
        )
        ctx.insert(book)
        #expect(book.totalPositions == 0)
    }

    @Test func localBookHasNilCatalogFields() throws {
        let ctx = try makeContext()
        let localSrc = testSource(kind: .local, into: ctx)
        let book = Book(
            source: localSrc,
            title: "T",
            authors: ["A"],
            format: .epub
        )
        ctx.insert(book)
        #expect(book.source.kind == .local)
        #expect(book.serverID == nil)
        #expect(book.serverIDProtocol == nil)
        #expect(book.acquisitionURL == nil)
        #expect(book.koboBookUUID == nil)
        #expect(book.thumbnailURL == nil)
        #expect(book.archived == false)
    }
}
