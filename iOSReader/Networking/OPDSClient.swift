import Foundation
import Core
import ReadiumOPDS
import ReadiumShared

/// Fetches and parses OPDS 1.x catalog feeds.
protocol OPDSClientProtocol: Sendable {
    func fetchCatalog(url: URL) async throws -> OPDSCatalog
}

/// Concrete OPDS client backed by ``Core/HTTPClient`` and the Readium OPDS 1.x parser.
struct OPDSClient: OPDSClientProtocol, Sendable {
    let http: Core.HTTPClient

    init(http: Core.HTTPClient) {
        self.http = http
    }

    func fetchCatalog(url: URL) async throws -> OPDSCatalog {
        let (data, response) = try await http.data(for: URLRequest(url: url))
        let parseData = try OPDS1Parser.parse(xmlData: data, url: url, response: response)
        guard let feed = parseData.feed else {
            throw OPDSClientError.notAFeed
        }
        return Self.transform(feed, sourceURL: url)
    }

    // MARK: - Private helpers

    private static func transform(_ feed: Feed, sourceURL: URL) -> OPDSCatalog {
        let entries: [OPDSEntry] = feed.publications.compactMap { pub in
            makeEntry(from: pub, sourceURL: sourceURL)
        }

        let nextURL: URL? = feed.links
            .firstWithRel(.next)
            .flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }

        return OPDSCatalog(
            title: feed.metadata.title,
            entries: entries,
            nextURL: nextURL
        )
    }

    // OPDS acquisition rels: https://specs.opds.io/opds-1.2#25-acquisition-relations
    private static let acquisitionRels: Set<String> = [
        "http://opds-spec.org/acquisition",
        "http://opds-spec.org/acquisition/open-access",
        "http://opds-spec.org/acquisition/buy",
        "http://opds-spec.org/acquisition/borrow",
        "http://opds-spec.org/acquisition/sample",
        "http://opds-spec.org/acquisition/subscribe",
    ]

    private static func makeEntry(from pub: Publication, sourceURL: URL) -> OPDSEntry? {
        // Find the first acquisition link (exact or sub-rel).
        guard let acqLink = pub.links.first(where: { link in
            link.rels.contains { acquisitionRels.contains($0.string) }
        }) else {
            return nil
        }

        // Resolve the href against the source URL.
        guard let acquisitionURL = URL(string: acqLink.href, relativeTo: sourceURL)?.absoluteURL else {
            return nil
        }

        // Map MIME type to BookFormat.
        guard let mimeString = acqLink.mediaType?.string,
              let format = BookFormat(mimeType: mimeString) else {
            return nil
        }

        let title = pub.metadata.title ?? ""
        let authors = pub.metadata.authors.map(\.name)
        let serverID = pub.metadata.identifier ?? acquisitionURL.absoluteString

        // Detail URL: entry's self link.
        let detailURL: URL? = pub.links
            .firstWithRel(.self)
            .flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }

        return OPDSEntry(
            serverID: serverID,
            title: title,
            authors: authors,
            detailURL: detailURL,
            acquisitionURL: acquisitionURL,
            format: format
        )
    }
}

/// Errors thrown by ``OPDSClient``.
enum OPDSClientError: Error, LocalizedError {
    /// The OPDS resource parsed as a publication entry, not a feed.
    case notAFeed

    var errorDescription: String? {
        switch self {
        case .notAFeed:
            return "Server returned something other than an OPDS feed."
        }
    }
}
