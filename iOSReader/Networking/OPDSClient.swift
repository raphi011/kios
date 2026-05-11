import Foundation
import Core
import ReadiumOPDS
import ReadiumShared

protocol OPDSClientProtocol: Sendable {
    func fetchFeed(url: URL) async throws -> OPDSFeed
    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor
    func invalidate(_ url: URL) async
    func invalidateAll() async
}

/// OPDS 1.2 client backed by Readium's OPDS1Parser.
///
/// An actor so the session feed cache is naturally Sendable without locks.
/// Each `fetchFeed(url:)` consults the cache before making a network request;
/// pull-to-refresh in the UI calls `invalidate(_:)` first to force a re-fetch.
actor OPDSClient: OPDSClientProtocol {
    private let http: Core.HTTPClient
    /// Session feed cache. Unbounded by design per spec §6 ("each feed is
    /// ~50 KB and a realistic session loads <100 distinct feeds ≈5 MB
    /// worst case"). If this becomes a problem, swap for NSCache —
    /// one-file change. `invalidateAll()` clears it on sign-out.
    private var feedCache: [URL: OPDSFeed] = [:]
    /// Session OpenSearch descriptor cache. Lazily fetched per feed, cached
    /// per URL. Cleared by `invalidateAll()` on sign-out.
    private var searchDescriptorCache: [URL: OpenSearchDescriptor] = [:]

    init(http: Core.HTTPClient) {
        self.http = http
    }

    func fetchFeed(url: URL) async throws -> OPDSFeed {
        if let cached = feedCache[url] {
            return cached
        }
        let feed = try await downloadAndParse(url: url)
        feedCache[url] = feed
        return feed
    }

    func fetchSearchDescriptor(at url: URL) async throws -> OpenSearchDescriptor {
        if let cached = searchDescriptorCache[url] {
            return cached
        }
        let (data, _) = try await http.data(for: URLRequest(url: url))
        guard let descriptor = Self.parseOpenSearchDescriptor(data: data) else {
            throw OPDSClientError.invalidOpenSearchDescriptor
        }
        searchDescriptorCache[url] = descriptor
        return descriptor
    }

    func invalidate(_ url: URL) {
        feedCache.removeValue(forKey: url)
    }

    func invalidateAll() {
        feedCache.removeAll()
        searchDescriptorCache.removeAll()
    }

    // MARK: - Parsing

    private func downloadAndParse(url: URL) async throws -> OPDSFeed {
        let (data, response) = try await http.data(for: URLRequest(url: url))
        let parseData = try OPDS1Parser.parse(xmlData: data, url: url, response: response)
        guard let feed = parseData.feed else { throw OPDSClientError.notAFeed }
        return Self.transform(feed, sourceURL: url)
    }

    private static func parseOpenSearchDescriptor(data: Data) -> OpenSearchDescriptor? {
        // Minimal XML walk — find the first <Url ... template="..."> with
        // {searchTerms} in the template. Prefer atom+xml type when multiple
        // candidates exist (OpenSearch description docs commonly list both
        // an HTML and an atom+xml endpoint). Avoid pulling a full XML lib.
        final class Delegate: NSObject, XMLParserDelegate {
            var found: String?
            func parser(_ parser: XMLParser, didStartElement elementName: String,
                        namespaceURI: String?, qualifiedName qName: String?,
                        attributes attributeDict: [String: String] = [:]) {
                guard elementName.caseInsensitiveCompare("Url") == .orderedSame,
                      let template = attributeDict["template"],
                      template.contains("{searchTerms}") else { return }
                let type = attributeDict["type"] ?? ""
                if found == nil || type.contains("atom+xml") {
                    found = template
                }
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse(), let template = delegate.found,
              let url = URL(string: template) else { return nil }
        return OpenSearchDescriptor(templateURL: url)
    }

    static func transform(_ feed: ReadiumShared.Feed, sourceURL: URL) -> OPDSFeed {
        let nav: [OPDSFeed.Entry] = feed.navigation.compactMap { link in
            makeNavEntry(link: link, sourceURL: sourceURL).map(OPDSFeed.Entry.navigation)
        }
        let acq: [OPDSFeed.Entry] = feed.publications.compactMap { pub in
            makeAcquisitionEntry(pub: pub, sourceURL: sourceURL).map(OPDSFeed.Entry.acquisition)
        }
        let nextURL = feed.links.firstWithRel(.next)
            .flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }
        let searchURL = feed.links.first(where: { link in
            link.rels.contains(where: { $0.string == "search" }) &&
            (link.mediaType?.string ?? "").contains("opensearchdescription")
        }).flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }
        return OPDSFeed(
            title: feed.metadata.title,
            entries: nav + acq,
            nextURL: nextURL,
            searchDescriptorURL: searchURL
        )
    }

    private static func makeNavEntry(link: ReadiumShared.Link, sourceURL: URL) -> NavigationEntry? {
        guard let href = URL(string: link.href, relativeTo: sourceURL)?.absoluteURL else {
            return nil
        }
        let rawTitle = link.title ?? ""
        // CWA's letter index uses literal title "00" for its synthetic "All" entry.
        let title = (rawTitle == "00") ? "All" : rawTitle
        return NavigationEntry(
            id: href.absoluteString,    // see OPDSFeed.swift comment — atom:id unreliable on CWA
            title: title,
            summary: nil,
            href: href
        )
    }

    private static let acquisitionRels: Set<String> = [
        "http://opds-spec.org/acquisition",
        "http://opds-spec.org/acquisition/open-access",
        "http://opds-spec.org/acquisition/buy",
        "http://opds-spec.org/acquisition/borrow",
        "http://opds-spec.org/acquisition/sample",
        "http://opds-spec.org/acquisition/subscribe",
    ]

    private static func makeAcquisitionEntry(
        pub: ReadiumShared.Publication, sourceURL: URL
    ) -> AcquisitionEntry? {
        let acquisitions: [Acquisition] = pub.links.compactMap { link in
            guard link.rels.contains(where: { acquisitionRels.contains($0.string) }) else {
                return nil
            }
            guard let url = URL(string: link.href, relativeTo: sourceURL)?.absoluteURL,
                  let mime = link.mediaType?.string,
                  let format = BookFormat(mimeType: mime) else { return nil }
            return Acquisition(href: url, mimeType: mime, format: format)
        }
        guard !acquisitions.isEmpty else { return nil }

        // OPDS1Parser segregates image links into two buckets at parse time:
        // - rel="http://opds-spec.org/image" → pub.images (exact match)
        // - rel="http://opds-spec.org/image/thumbnail" → pub.links
        //   (the parser checks for "image-thumbnail" with a dash, which never matches
        //    the spec's "image/thumbnail" with a slash, so thumbnails fall through to links)
        let thumb = pub.links.first(where: { link in
            link.rels.contains(where: { $0.string == "http://opds-spec.org/image/thumbnail" })
        }).flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }
        let cover = pub.images.first(where: { link in
            link.rels.contains(where: { $0.string == "http://opds-spec.org/image" })
        }).flatMap { URL(string: $0.href, relativeTo: sourceURL)?.absoluteURL }

        return AcquisitionEntry(
            serverID: pub.metadata.identifier ?? acquisitions[0].href.absoluteString,
            title: pub.metadata.title ?? "",
            authors: pub.metadata.authors.map(\.name),
            summary: pub.metadata.description,
            publishedAt: pub.metadata.published,
            acquisitions: acquisitions,
            thumbnailURL: thumb,
            coverURL: cover
        )
    }
}

enum OPDSClientError: Error, LocalizedError {
    case notAFeed
    case invalidOpenSearchDescriptor
    case unsupportedAcquisition

    var errorDescription: String? {
        switch self {
        case .notAFeed:
            return "Server returned something other than an OPDS feed."
        case .invalidOpenSearchDescriptor:
            return "Server returned an invalid OpenSearch description."
        case .unsupportedAcquisition:
            return "Entry has no downloadable acquisition link."
        }
    }
}
