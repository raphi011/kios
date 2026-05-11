import Testing
import Foundation
import SwiftData
import Core
@testable import iOSReader

// MARK: - Test catalog backend

/// Returns a canned list of CatalogEntry. `resolveDownload` is unused by
/// LibraryService.refresh so it just echoes the entry's downloadURL.
struct MockCatalogBackend: CatalogBackend {
    let entries: [CatalogEntry]

    func listLibrary() async throws -> [CatalogEntry] { entries }

    func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        entry.downloadURL
    }
}

// MARK: - Helpers

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Book.self, ReadingProgress.self, Download.self,
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

private func makeBook(
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
        let entry = makeEntry(
            serverID: "srv-new",
            title: "New Book",
            authors: ["Alice"],
            partialMD5: "md5-1"
        )
        let backend = MockCatalogBackend(entries: [entry])

        try await service.refresh(using: backend, activeProtocol: .kosync)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverID == "srv-new")
        #expect(books[0].title == "New Book")
        #expect(books[0].authors == ["Alice"])
        #expect(books[0].partialMD5 == "md5-1")
        #expect(books[0].archived == false)
    }

    @Test func refreshArchivesMissingBooks() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(title: "Gone", partialMD5: "stale")
        context.insert(local)
        try context.save()

        let backend = MockCatalogBackend(entries: [])
        try await service.refresh(using: backend, activeProtocol: .kosync)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].archived == true)
    }

    @Test func refreshUnarchivesReappearingBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
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
        try await service.refresh(using: backend, activeProtocol: .kosync)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].archived == false)
    }

    @Test func refreshMatchesByExactKoboUUID() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
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
        try await service.refresh(using: backend, activeProtocol: .kobo)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "kobo-uuid-1")
    }

    @Test func refreshMatchesByExactPartialMD5() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
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
        try await service.refresh(using: backend, activeProtocol: .kosync)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].partialMD5 == "md5-match")
    }

    @Test func refreshMatchesByNormalizedTitleAndAuthors() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
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
        try await service.refresh(using: backend, activeProtocol: .kobo)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "kobo-uuid-merge")
        #expect(books[0].partialMD5 == "md5-local")
    }

    @Test func refreshFillsMissingPartialMD5WithoutOverwrite() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
            title: "Same", authors: ["Same"], partialMD5: "local-md5"
        )
        context.insert(local)
        try context.save()

        // Catalog claims a different md5 — must NOT overwrite.
        let entry = makeEntry(
            title: "Same", authors: ["Same"], partialMD5: "remote-md5"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, activeProtocol: .kosync)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].partialMD5 == "local-md5")
    }

    @Test func refreshFillsMissingKoboUUIDWithoutOverwrite() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
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
        try await service.refresh(using: backend, activeProtocol: .kobo)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].koboBookUUID == "local-uuid")
    }

    @Test func refreshPreservesServerIDProtocolOnMatchedBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let local = makeBook(
            serverIDProtocol: "kosync",
            title: "Same",
            authors: ["Same"],
            partialMD5: "md5-same"
        )
        context.insert(local)
        try context.save()

        // Refresh under .kobo — but the matched book keeps "kosync".
        let entry = makeEntry(
            title: "Same",
            authors: ["Same"],
            partialMD5: "md5-same",
            koboBookUUID: "kobo-uuid"
        )
        let backend = MockCatalogBackend(entries: [entry])
        try await service.refresh(using: backend, activeProtocol: .kobo)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverIDProtocol == "kosync")
        #expect(books[0].koboBookUUID == "kobo-uuid")
    }

    @Test func refreshSetsServerIDProtocolFromActiveProtocolOnNewBook() async throws {
        let context = try makeContext()
        let service = LibraryService(context: context)
        let entry = makeEntry(
            title: "Brand New",
            authors: ["Author"],
            koboBookUUID: "kobo-new"
        )
        let backend = MockCatalogBackend(entries: [entry])

        try await service.refresh(using: backend, activeProtocol: .kobo)

        let books = try context.fetch(FetchDescriptor<Book>())
        #expect(books.count == 1)
        #expect(books[0].serverIDProtocol == "kobo")
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
