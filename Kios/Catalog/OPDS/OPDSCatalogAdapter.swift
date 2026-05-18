import Foundation
import Core

/// Adapts the existing `OPDSClient` to the `CatalogBackend` protocol.
///
/// Walks all feed pages via `nextURL` (capped at `maxFeedPages` for safety),
/// drops navigation entries, and compresses each multi-format acquisition
/// down to a single preferred-format `CatalogEntry`.
///
/// Identity at catalog time is empty for kosync-source books — OPDS feeds
/// don't carry a partial MD5 (that's computed locally after download).
/// Phase 8's library merge populates `partialMD5` if a matching local
/// `Book` already has it.
struct OPDSCatalogAdapter: CatalogBackend {
    /// Hard cap on pagination walks. A realistic CWA library has ~10 pages
    /// of 60 entries each (~600 books); 100 pages is ~6000 books — well
    /// beyond any plausible personal library, and a tripwire for misbehaving
    /// servers that return circular `next` links.
    static let maxFeedPages = 100

    let client: OPDSClientProtocol
    /// Root OPDS feed URL — typically `<server>/opds/`. The caller composes
    /// this from `AuthStore.load().serverURL` plus the canonical OPDS path.
    let rootURL: URL

    func probe() async throws {
        _ = try await client.fetchFeed(url: rootURL)
    }

    func listLibrary() async throws -> [CatalogEntry] {
        var results: [CatalogEntry] = []
        var pageURL: URL? = rootURL
        var pageCount = 0
        while let url = pageURL {
            pageCount += 1
            if pageCount > Self.maxFeedPages {
                throw OPDSCatalogAdapterError.feedPaginationOverflow
            }
            let feed = try await client.fetchFeed(url: url)
            for entry in feed.entries {
                guard case .acquisition(let a) = entry,
                      let chosen = Self.preferredAcquisition(a.acquisitions) else { continue }
                results.append(CatalogEntry(
                    serverID: a.serverID,
                    title: a.title,
                    authors: a.authors,
                    identity: BookIdentity(partialMD5: nil, koboBookUUID: nil),
                    downloadURL: chosen.href,
                    format: chosen.format,
                    thumbnailURL: a.thumbnailURL
                ))
            }
            pageURL = feed.nextURL
        }
        return results
    }

    /// OPDS has no token-refresh or pre-signed URL flow — the acquisition
    /// URL captured at listLibrary time IS the download URL.
    func resolveDownload(for entry: CatalogEntry) async throws -> URL? {
        entry.downloadURL
    }

    /// EPUB is preferred — best Reader support and the most common OPDS
    /// format. Falls back to the first available acquisition when EPUB
    /// is absent (e.g. PDF-only or CBZ-only entries).
    private static func preferredAcquisition(_ acquisitions: [Acquisition]) -> Acquisition? {
        acquisitions.first(where: { $0.format == .epub }) ?? acquisitions.first
    }
}

enum OPDSCatalogAdapterError: Error, Equatable {
    case feedPaginationOverflow
}
