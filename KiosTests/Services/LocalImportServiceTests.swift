import Testing
import Foundation
import SwiftData
import Core
@testable import Kios

@Suite("LocalImportService", .serialized)
@MainActor
struct LocalImportServiceTests {

    /// Per-test sandbox: a fresh temp directory the service writes into,
    /// and a fresh in-memory ModelContext. The directory is removed at the
    /// end of `/tmp` cleanup; we don't bother with deinit because Swift
    /// Testing doesn't give us a hook for it on a struct suite.
    private struct Harness {
        let service: LocalImportService
        let context: ModelContext
        let booksDir: URL
    }

    private func makeHarness() throws -> Harness {
        let container = try ModelContainer.kiosInMemory()
        let ctx = ModelContext(container)
        let booksDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kios-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: booksDir, withIntermediateDirectories: true
        )
        let svc = LocalImportService(context: ctx, booksDirectory: booksDir)
        return Harness(service: svc, context: ctx, booksDir: booksDir)
    }

    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: TestBundleClass.self)
        let url = bundle.url(forResource: name, withExtension: nil)
        return try #require(url, "missing fixture \(name)")
    }

    @Test func importsValidEpubAndCreatesLocalBookRow() async throws {
        let h = try makeHarness()
        let src = try fixture("sample.epub")

        let result = try await h.service.import(from: src)
        guard case .imported(let book) = result else {
            Issue.record("expected .imported, got \(result)")
            return
        }

        #expect(book.source == .local)
        #expect(book.title == "Sample Book")
        #expect(book.authors == ["Test Author"])
        #expect(book.format == .epub)
        #expect(book.partialMD5 != nil)
        let filename = try #require(book.filename)

        // The bytes landed in the injected books directory. We deliberately
        // do NOT check `book.fileURL` — that resolves through
        // `AppPaths.booksDirectory` (the real app container), not our temp
        // directory.
        let dest = h.booksDir.appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func dedupReturnsExistingByPartialMD5() async throws {
        let h = try makeHarness()
        let src = try fixture("sample.epub")

        // First import lands a row.
        let first = try await h.service.import(from: src)
        guard case .imported(let firstBook) = first else {
            Issue.record("first import should be .imported"); return
        }
        let firstID = firstBook.id
        let knownHash = try #require(firstBook.partialMD5)

        // Second import of the same file hits dedup.
        let second = try await h.service.import(from: src)
        guard case .existing(let existing) = second else {
            Issue.record("second import should be .existing, got \(second)")
            return
        }
        #expect(existing.id == firstID)
        #expect(existing.partialMD5 == knownHash)

        // Exactly one row in the store.
        let rows = try h.context.fetch(FetchDescriptor<Book>())
        #expect(rows.count == 1)

        // No orphaned files in the test books directory.
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.booksDir.path)
        let epubs = entries.filter { $0.hasSuffix(".epub") }
        #expect(epubs.count == 1)
    }

    @Test func dedupHitsAcrossSyncedRow() async throws {
        let h = try makeHarness()
        let src = try fixture("sample.epub")

        // Pre-compute the hash and pre-insert a .synced Book with that hash.
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-probe-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: src, to: tempCopy)
        defer { try? FileManager.default.removeItem(at: tempCopy) }
        let knownHash = try DocumentHasher.partialMD5(of: tempCopy)

        let syncedBook = Book(
            serverID: "srv-existing",
            serverIDProtocol: "kosync",
            title: "Already Synced",
            authors: ["A"],
            opdsHref: nil,
            acquisitionURL: URL(string: "https://x")!,
            format: .epub,
            koboBookUUID: nil,
            archived: false,
            partialMD5: knownHash
        )
        h.context.insert(syncedBook)
        try h.context.save()

        // Import the same content locally — should dedupe to the synced row,
        // not create a .local copy or flip the source.
        let result = try await h.service.import(from: src)
        guard case .existing(let hit) = result else {
            Issue.record("expected .existing, got \(result)")
            return
        }
        #expect(hit.id == syncedBook.id)
        #expect(hit.source == .synced)  // no flip!
        #expect(hit.title == "Already Synced")

        let rows = try h.context.fetch(FetchDescriptor<Book>())
        #expect(rows.count == 1)
    }

    @Test func throwsNoTitleWhenOPFMissingTitle() async throws {
        let h = try makeHarness()
        let src = try fixture("no-title.epub")

        await #expect(throws: LocalImportError.noTitle) {
            _ = try await h.service.import(from: src)
        }

        // No row inserted.
        let rows = try h.context.fetch(FetchDescriptor<Book>())
        #expect(rows.isEmpty)

        // No leftover epub or cover files in the test books directory.
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.booksDir.path)
        let leftover = entries.filter { $0.hasSuffix(".epub") || $0.hasSuffix(".cover.jpg") }
        #expect(leftover.isEmpty)
    }

    @Test func cleansUpFileOnParseFailure() async throws {
        let h = try makeHarness()
        let src = try fixture("corrupt.epub")

        do {
            _ = try await h.service.import(from: src)
            Issue.record("expected throw, got success")
        } catch is LocalImportError {
            // expected
        }

        let rows = try h.context.fetch(FetchDescriptor<Book>())
        #expect(rows.isEmpty)

        let entries = try FileManager.default.contentsOfDirectory(atPath: h.booksDir.path)
        let leftover = entries.filter { $0.hasSuffix(".epub") || $0.hasSuffix(".cover.jpg") }
        #expect(leftover.isEmpty)
    }
}

/// Anchor class for `Bundle(for:)` — gives us the test bundle so we can
/// look up fixture resources without relying on `Bundle.module` (which
/// requires SPM package targets).
private final class TestBundleClass {}
