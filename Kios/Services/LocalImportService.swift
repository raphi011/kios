import Foundation
import SwiftData
import Core
import ReadiumShared
import ReadiumStreamer

/// Result of `LocalImportService.import(from:)`.
enum LocalImportResult: Equatable {
    /// The file was new — bytes copied, metadata parsed, Book row inserted.
    case imported(Book)
    /// A Book with the same `partialMD5` already exists (synced or local).
    /// The freshly-copied file was discarded and the existing row is returned.
    case existing(Book)

    static func == (lhs: LocalImportResult, rhs: LocalImportResult) -> Bool {
        switch (lhs, rhs) {
        case (.imported(let a), .imported(let b)): return a.id == b.id
        case (.existing(let a), .existing(let b)): return a.id == b.id
        default: return false
        }
    }
}

enum LocalImportError: Error, Equatable {
    case unsupportedFormat
    case readFailed(String)
    case parseFailed(String)
    case copyFailed(String)
    case noTitle
}

/// Foreground-only service that ingests a local `.epub` file into the
/// library. Mirrors `DownloadService` in shape but writes to disk
/// synchronously and does not maintain a background URLSession.
@MainActor
final class LocalImportService {
    private let context: ModelContext
    /// Directory the service writes EPUBs and covers into. Defaults to
    /// `AppPaths.booksDirectory`; tests inject a per-test temp directory
    /// to avoid polluting the real app container and to keep file-count
    /// assertions deterministic.
    private let booksDirectory: URL

    init(context: ModelContext, booksDirectory: URL = AppPaths.booksDirectory) {
        self.context = context
        self.booksDirectory = booksDirectory
        try? FileManager.default.createDirectory(
            at: booksDirectory, withIntermediateDirectories: true
        )
    }

    /// Imports the EPUB at `sourceURL` into the library.
    /// - Parameter sourceURL: file:// or security-scoped URL.
    /// - Returns: `.imported` for new books, `.existing` for dedup hits.
    /// - Throws: `LocalImportError`.
    func `import`(from sourceURL: URL) async throws -> LocalImportResult {
        throw LocalImportError.parseFailed("not implemented")
    }
}
