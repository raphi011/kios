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
}

/// Anchor class for `Bundle(for:)` — gives us the test bundle so we can
/// look up fixture resources without relying on `Bundle.module` (which
/// requires SPM package targets).
private final class TestBundleClass {}
