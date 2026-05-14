// Kios/Services/AI/PublicationChapterTextExtractor.swift
import Foundation
import ReadiumShared

/// Adapter bridging the per-reader Readium `Publication` to the
/// `AIChapterTextExtracting` protocol consumed by `AISummaryService`.
///
/// Resolves a string `chapterHref` to the matching reading-order `Link`
/// (tolerating href/anchor mismatches the same way `ReaderView`'s TOC walker
/// does), then defers to `ChapterTextExtractor` for the HTML→plain-text
/// extraction and cutoff alignment.
///
/// `@unchecked Sendable` is required because `Publication` isn't `Sendable`,
/// but the wrapped instance is only read here and Readium routes the actual
/// resource read through its own internal serialization.
final class PublicationChapterTextExtractor: AIChapterTextExtracting, @unchecked Sendable {
    private let publication: Publication

    init(publication: Publication) {
        self.publication = publication
    }

    func extract(bookID: UUID, chapterHref: String, cutoff: Double?) async throws -> String {
        let link = try resolveLink(for: chapterHref)
        let extractor = ChapterTextExtractor(publication: publication)
        return try await extractor.extract(link: link, cutoff: cutoff)
    }

    /// Best-effort match between a stored chapter href (possibly with an
    /// `#anchor`, possibly relative to the EPUB root vs. the OPF) and a
    /// reading-order entry. Mirrors the suffix-tolerant comparison used in
    /// `ReaderView.buildTOCProgressions`.
    private func resolveLink(for chapterHref: String) throws -> Link {
        let resource = chapterHref.components(separatedBy: "#").first ?? chapterHref

        if let exact = publication.readingOrder.first(where: { $0.href == chapterHref }) {
            return exact
        }
        if let byResource = publication.readingOrder.first(where: { $0.href == resource }) {
            return byResource
        }
        if let fuzzy = publication.readingOrder.first(where: {
            $0.href.hasSuffix(resource) || resource.hasSuffix($0.href)
        }) {
            return fuzzy
        }
        throw ResolveError.linkNotFound(chapterHref)
    }

    enum ResolveError: LocalizedError {
        case linkNotFound(String)
        var errorDescription: String? {
            switch self {
            case .linkNotFound(let href):
                return "Chapter not found in reading order: \(href)"
            }
        }
    }
}
