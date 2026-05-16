import Foundation
import UIKit
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

extension LocalImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            String(localized: "import.error.unsupportedFormat",
                   defaultValue: "Kios can only import EPUB files right now.")
        case .readFailed(let detail):
            String(
                format: String(localized: "import.error.readFailed",
                               defaultValue: "Couldn't read the file. %@"),
                detail
            )
        case .parseFailed:
            String(localized: "import.error.parseFailed",
                   defaultValue: "This EPUB seems to be damaged.")
        case .copyFailed(let detail):
            String(
                format: String(localized: "import.error.copyFailed",
                               defaultValue: "Couldn't save the file. %@"),
                detail
            )
        case .noTitle:
            String(localized: "import.error.noTitle",
                   defaultValue: "This EPUB has no title metadata and can't be imported.")
        }
    }
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
        // 1. Validate extension before incurring I/O cost.
        guard sourceURL.pathExtension.lowercased() == "epub" else {
            throw LocalImportError.unsupportedFormat
        }

        // 2. Security-scoped access (no-op if not scoped).
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        // 3. Copy to books directory under a fresh UUID.
        let bookUUID = UUID()
        let destFilename = "\(bookUUID.uuidString).epub"
        let dest = booksDirectory.appendingPathComponent(destFilename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            throw LocalImportError.copyFailed(error.localizedDescription)
        }

        // From this point on, any failure must remove `dest`.
        func cleanup() { try? FileManager.default.removeItem(at: dest) }

        // 4. Hash for dedup.
        let hash: String
        do {
            hash = try DocumentHasher.partialMD5(of: dest)
        } catch {
            cleanup()
            throw LocalImportError.readFailed(error.localizedDescription)
        }

        // 5. Dedup against existing Book rows (any source).
        // Fetch all books and filter in-memory to avoid #Predicate issues
        // with Optional<String> keypaths and strict-concurrency runtime checks.
        var allBooksDescriptor = FetchDescriptor<Book>()
        allBooksDescriptor.fetchLimit = 2000
        if let existing = try? context.fetch(allBooksDescriptor).first(where: { $0.partialMD5 == hash }) {
            cleanup()
            return .existing(existing)
        }

        // 6. Parse metadata via Readium.
        let parsed: ParsedMetadata
        do {
            parsed = try await parseMetadata(from: dest)
        } catch let err as LocalImportError {
            cleanup()
            throw err
        } catch {
            cleanup()
            throw LocalImportError.parseFailed(error.localizedDescription)
        }
        guard let title = parsed.title, !title.isEmpty else {
            cleanup()
            throw LocalImportError.noTitle
        }

        // 7. Write cover bytes if Readium gave us any.
        var coverFilename: String? = nil
        if let coverData = parsed.coverImageData {
            let name = AppPaths.coverFilename(for: bookUUID)
            let coverURL = booksDirectory.appendingPathComponent(name)
            do {
                try coverData.write(to: coverURL, options: .atomic)
                coverFilename = name
            } catch {
                // Non-fatal: surfaced as a missing cover, not as an import failure.
            }
        }

        // 8. Insert the Book row.
        let book = Book(
            source: .local,
            id: bookUUID,
            title: title,
            authors: parsed.authors,
            format: .epub,
            filename: destFilename,
            partialMD5: hash,
            coverFilename: coverFilename
        )
        context.insert(book)
        try? context.save()
        return .imported(book)
    }

    // MARK: - Metadata parsing

    private struct ParsedMetadata {
        let title: String?
        let authors: [String]
        let coverImageData: Data?
    }

    private nonisolated func parseMetadata(from fileURL: URL) async throws -> ParsedMetadata {
        // Open the EPUB via Readium's AssetRetriever + PublicationOpener
        // (same pattern used in ReaderView.openPublication).
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL_ = FileURL(url: fileURL) else {
            throw LocalImportError.parseFailed("Readium rejected the file URL: \(fileURL.absoluteString)")
        }

        let asset: Asset = try await assetRetriever.retrieve(url: fileURL_)
            .mapError { err -> LocalImportError in
                .parseFailed("Asset retrieval failed: \(err.localizedDescription)")
            }
            .get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        let publication: Publication = try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { err -> LocalImportError in
                .parseFailed("Publication open failed: \(err.localizedDescription)")
            }
            .get()

        let metadata = publication.metadata
        let title = metadata.title
        let authors = metadata.authors.map { $0.name }

        // Cover is best-effort. sample.epub declares no cover image, so
        // coverImageData will be nil for that fixture — that's correct.
        // cover() returns ReadResult<UIImage?>; getOrNil() gives UIImage??.
        let coverImage: UIImage? = await publication.cover().getOrNil() ?? nil
        let coverData = coverImage?.jpegData(compressionQuality: 0.85)

        return ParsedMetadata(title: title, authors: authors, coverImageData: coverData)
    }
}
