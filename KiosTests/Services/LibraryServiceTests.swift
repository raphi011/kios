import Testing
import Foundation
import SwiftData
import Core
@testable import Kios

// MARK: - Test catalog backend

/// Returns a canned list of CatalogEntry. `resolveDownload` is unused by
/// LibraryService.refresh so it just echoes the entry's downloadURL.
struct MockCatalogBackend: CatalogBackend {
    let entries: [CatalogEntry]

    func listLibrary() async throws -> [CatalogEntry] { entries }

    func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        entry.downloadURL
    }

    func probe() async throws {}
}

// MARK: - Helpers

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Book.self, Source.self, ReadingProgress.self, Download.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

private func makeEntry(
    serverID: String = "srv-1",
    title: String = "T",
    authors: [String] = ["A"],
    partialMD5: String? = nil,
    koboBookUUID: String? = nil,
    format: BookFormat = .epub,
    thumbnailURL: URL? = nil
) -> CatalogEntry {
    CatalogEntry(
        serverID: serverID,
        title: title,
        authors: authors,
        identity: BookIdentity(partialMD5: partialMD5, koboBookUUID: koboBookUUID),
        downloadURL: URL(string: "https://x")!,
        format: format,
        thumbnailURL: thumbnailURL
    )
}

@MainActor
private func makeBook(
    source: Source,
    serverID: String = "srv-local",
    serverIDProtocol: String = "kosync",
    title: String = "T",
    authors: [String] = ["A"],
    partialMD5: String? = nil,
    koboBookUUID: String? = nil,
    archived: Bool = false,
    format: BookFormat = .epub
) -> Book {
    Book(
        source: source,
        serverID: serverID,
        serverIDProtocol: serverIDProtocol,
        title: title,
        authors: authors,
        opdsHref: URL(string: "https://x"),
        acquisitionURL: URL(string: "https://x")!,
        format: format,
        koboBookUUID: koboBookUUID,
        archived: archived,
        partialMD5: partialMD5
    )
}

// MARK: - refresh suite

@Suite("LibraryService.refresh", .serialized)
@MainActor
struct LibraryServiceRefreshTests {

    @Test func refreshInsertsNewBookFromCatalog() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kosync, displayName: "KoSync",
                                serverURL: URL(string: "https://sync.example.com"),
                                sortOrder: 0, into: context)
        let entry = makeEntry(
            serverID: "srv-new",
            title: "New Book",
            authors: ["Alice"],
            partialMD5: "md5-1"
        )
        let backend = MockCatalogBackend(entries: [entry])

        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverID == "srv-new")
        #expect(books[0].title == "New Book")
        #expect(books[0].authors == ["Alice"])
        #expect(books[0].partialMD5 == "md5-1")
        #expect(books[0].archived == false)
        #expect(books[0].serverIDProtocol == "kosync")
    }

    @Test func refreshArchivesMissingBooks() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kosync, displayName: "KoSync",
                                serverURL: URL(string: "https://sync.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(source: source, title: "Gone", partialMD5: "stale")
        context.insert(local)
        try context.save()

        let backend = MockCatalogBackend(entries: [])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].archived == true)
    }

    @Test func refreshUnarchivesReappearingBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kosync, displayName: "KoSync",
                                serverURL: URL(string: "https://sync.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(
            source: source,
            title: "Returned",
            authors: ["Alice"],
            partialMD5: "md5-r",
            archived: true
        )
        context.insert(local)
        try context.save()

        let entry = makeEntry(
            title: "Returned", authors: ["Alice"], partialMD5: "md5-r"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].archived == false)
    }

    @Test func refreshMatchesByExactKoboUUID() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kobo, displayName: "Kobo",
                                serverURL: URL(string: "https://kobo.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(
            source: source,
            serverIDProtocol: "kobo",
            title: "Different Title",
            authors: ["Different Author"],
            koboBookUUID: "kobo-uuid-1"
        )
        context.insert(local)
        try context.save()

        // Catalog has matching UUID but otherwise unrelated title/authors —
        // UUID match must win over the title/authors fallback.
        let entry = makeEntry(
            title: "Title from catalog",
            authors: ["Author from catalog"],
            koboBookUUID: "kobo-uuid-1"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "kobo-uuid-1")
    }

    @Test func refreshMatchesByExactPartialMD5() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kosync, displayName: "KoSync",
                                serverURL: URL(string: "https://sync.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(
            source: source,
            title: "Different",
            authors: ["Other"],
            partialMD5: "md5-match"
        )
        context.insert(local)
        try context.save()

        let entry = makeEntry(
            title: "Other Title",
            authors: ["Other Author"],
            partialMD5: "md5-match"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].partialMD5 == "md5-match")
    }

    @Test func refreshMatchesByNormalizedTitleAndAuthors() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let kosyncSource = testSource(kind: .kosync, displayName: "KoSync",
                                     serverURL: URL(string: "https://sync.example.com"),
                                     sortOrder: 0, into: context)
        let koboSource = testSource(kind: .kobo, displayName: "Kobo",
                                    serverURL: URL(string: "https://kobo.example.com"),
                                    sortOrder: 1, into: context)
        let local = makeBook(
            source: kosyncSource,
            serverIDProtocol: "kosync",
            title: "The Adventure!",
            authors: ["Alice  Smith"],
            partialMD5: "md5-local"
        )
        context.insert(local)
        try context.save()

        // Kobo-style entry: lowercased, no punctuation, single-space.
        let entry = makeEntry(
            title: "the adventure",
            authors: ["alice smith"],
            koboBookUUID: "kobo-uuid-merge"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: koboSource)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "kobo-uuid-merge")
        #expect(books[0].partialMD5 == "md5-local")
    }

    @Test func refreshFillsMissingPartialMD5WithoutOverwrite() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kosync, displayName: "KoSync",
                                serverURL: URL(string: "https://sync.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(
            source: source,
            title: "Same", authors: ["Same"], partialMD5: "local-md5"
        )
        context.insert(local)
        try context.save()

        // Catalog claims a different md5 — must NOT overwrite.
        let entry = makeEntry(
            title: "Same", authors: ["Same"], partialMD5: "remote-md5"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].partialMD5 == "local-md5")
    }

    @Test func refreshFillsMissingKoboUUIDWithoutOverwrite() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kobo, displayName: "Kobo",
                                serverURL: URL(string: "https://kobo.example.com"),
                                sortOrder: 0, into: context)
        let local = makeBook(
            source: source,
            title: "Same",
            authors: ["Same"],
            koboBookUUID: "local-uuid"
        )
        context.insert(local)
        try context.save()

        let entry = makeEntry(
            title: "Same", authors: ["Same"], koboBookUUID: "remote-uuid"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "local-uuid")
    }

    @Test func refreshPreservesServerIDProtocolOnMatchedBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let kosyncSource = testSource(kind: .kosync, displayName: "KoSync",
                                     serverURL: URL(string: "https://sync.example.com"),
                                     sortOrder: 0, into: context)
        let koboSource = testSource(kind: .kobo, displayName: "Kobo",
                                    serverURL: URL(string: "https://kobo.example.com"),
                                    sortOrder: 1, into: context)
        let local = makeBook(
            source: kosyncSource,
            serverIDProtocol: "kosync",
            title: "Same",
            authors: ["Same"],
            partialMD5: "md5-same"
        )
        context.insert(local)
        try context.save()

        // Refresh under kobo source — but the matched book keeps "kosync".
        let entry = makeEntry(
            title: "Same",
            authors: ["Same"],
            partialMD5: "md5-same",
            koboBookUUID: "kobo-uuid"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, source: koboSource)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverIDProtocol == "kosync")
        #expect(books[0].koboBookUUID == "kobo-uuid")
    }

    @Test func refreshSetsServerIDProtocolFromSourceKindOnNewBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let source = testSource(kind: .kobo, displayName: "Kobo",
                                serverURL: URL(string: "https://kobo.example.com"),
                                sortOrder: 0, into: context)
        let entry = makeEntry(
            title: "Brand New",
            authors: ["Author"],
            koboBookUUID: "kobo-new"
        )
        let backend = MockCatalogBackend(entries: [entry])

        try await service.refresh(using: backend, source: source)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverIDProtocol == "kobo")
    }
}

// MARK: - Local-book helper

@MainActor
private func makeLocalBook(
    title: String = "Local",
    partialMD5: String? = nil,
    addedAt: Date = .now,
    into ctx: ModelContext
) -> Book {
    let localSource = testSource(kind: .local, displayName: "Local",
                                 serverURL: nil, sortOrder: 999, into: ctx)
    return Book(
        source: localSource,
        title: title,
        authors: ["A"],
        format: .epub,
        filename: "local-\(UUID().uuidString).epub",
        partialMD5: partialMD5,
        addedAt: addedAt
    )
}

// MARK: - Local-book interaction suite

@Suite("LibraryService.refresh (local-book interactions)", .serialized)
@MainActor
struct LibraryServiceLocalTests {

    @Test func refreshDoesNotArchiveLocalBooks() async throws {
        let ctx = try makeContext()
        let kosyncSource = testSource(kind: .kosync, displayName: "KoSync",
                                     serverURL: URL(string: "https://sync.example.com"),
                                     sortOrder: 0, into: ctx)
        let local = makeLocalBook(title: "Just-imported", into: ctx)
        let synced = makeBook(source: kosyncSource, serverID: "srv-1", partialMD5: "hash-synced")
        ctx.insert(local)
        ctx.insert(synced)
        try ctx.save()

        let svc = LibraryService(context: ctx)
        // Catalog has neither book: synced should be archived, local untouched.
        try await svc.refresh(
            using: MockCatalogBackend(entries: []),
            source: kosyncSource
        )

        let rows = try ctx.fetch(FetchDescriptor<Book>())
        let localRow = try #require(rows.first { $0.title == "Just-imported" })
        let syncedRow = try #require(rows.first { $0.serverID == "srv-1" })
        #expect(localRow.archived == false)
        #expect(localRow.source.kind == .local)
        #expect(syncedRow.archived == true)
    }

    @Test func refreshPromotesLocalToSyncedOnPartialMD5Match() async throws {
        let ctx = try makeContext()
        let kosyncSource = testSource(kind: .kosync, displayName: "KoSync",
                                     serverURL: URL(string: "https://sync.example.com"),
                                     sortOrder: 0, into: ctx)
        let local = makeLocalBook(title: "T", partialMD5: "deadbeef", into: ctx)
        ctx.insert(local)
        try ctx.save()

        let svc = LibraryService(context: ctx)
        let entry = makeEntry(
            serverID: "srv-promoted",
            title: "T",
            authors: ["A"],
            partialMD5: "deadbeef"
        )
        try await svc.refresh(
            using: MockCatalogBackend(entries: [entry]),
            source: kosyncSource
        )

        let rows = try ctx.fetch(FetchDescriptor<Book>())
        #expect(rows.count == 1)
        let promoted = try #require(rows.first)
        #expect(promoted.source.kind == .kosync)
        #expect(promoted.serverID == "srv-promoted")
        #expect(promoted.serverIDProtocol == "kosync")
        #expect(promoted.acquisitionURL?.absoluteString == "https://x")
        #expect(promoted.archived == false)
    }

    @Test
    func refreshSourceALeavesSourceBUntouched() async throws {
        let ctx = try makeContext()
        let a = testSource(kind: .kosync, displayName: "A",
                           serverURL: URL(string: "https://a.example.com"),
                           sortOrder: 0, into: ctx)
        let b = testSource(kind: .kobo, displayName: "B",
                           serverURL: URL(string: "https://b.example.com"),
                           sortOrder: 1, into: ctx)
        let bOnly = Book(source: b, title: "B-only", authors: ["x"],
                         format: .epub)
        ctx.insert(bOnly)
        try ctx.save()

        let svc = LibraryService(context: ctx)
        let catalogA = MockCatalogBackend(entries: [
            makeEntry(serverID: "a1", title: "A-new", authors: ["y"])
        ])
        try await svc.refresh(using: catalogA, source: a)

        let allBooks = try ctx.fetch(FetchDescriptor<Book>())
        let bBooks = allBooks.filter { $0.source.id == b.id }
        #expect(bBooks.count == 1)
        #expect(bBooks.first?.title == "B-only")
        #expect(bBooks.first?.archived == false)
    }
}

// MARK: - normalize helper

@Suite("LibraryService.normalize")
struct LibraryServiceNormalizeTests {

    @Test func normalizationStripsPunctuationAndCase() {
        #expect(LibraryService.normalize("The Adventure!") == "theadventure")
        #expect(LibraryService.normalize("Alice  Smith") == "alicesmith")
        #expect(LibraryService.normalize("foo-bar_baz 123") == "foobarbaz123")
        #expect(LibraryService.normalize("") == "")
        // Diacritics intentionally preserved (Unicode-strict equality is not
        // the goal — visual match drives the fallback heuristic).
        #expect(LibraryService.normalize("café") == "café")
    }
}
