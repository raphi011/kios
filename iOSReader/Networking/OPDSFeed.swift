import Foundation

/// A parsed OPDS 1.2 feed. Entries are a sum type because a single feed can mix
/// navigation links (subsections) with acquisition entries (publications).
struct OPDSFeed: Sendable, Equatable {
    let title: String
    let entries: [Entry]
    /// `rel="next"` link, resolved absolute. nil on terminal page.
    let nextURL: URL?
    /// `rel="search"` link of type `application/opensearchdescription+xml`, resolved absolute.
    /// nil if the feed does not advertise search.
    let searchDescriptorURL: URL?

    enum Entry: Sendable, Equatable, Identifiable {
        case navigation(NavigationEntry)
        case acquisition(AcquisitionEntry)

        var id: String {
            switch self {
            case .navigation(let n): return n.id
            case .acquisition(let a): return a.serverID
            }
        }
    }
}

/// An OPDS navigation entry — a link to another feed (subsection, category, shelf).
struct NavigationEntry: Sendable, Equatable {
    /// `atom:id` of the entry. Used for SwiftUI identity.
    let id: String
    /// Display title. CWA's synthetic letter-index entry with id "/opds/books/letter/00"
    /// has the literal title "00"; we rewrite this to "All" at parse time.
    let title: String
    /// Optional summary text (`atom:content` or `atom:summary`).
    let summary: String?
    /// Resolved absolute URL of the target feed.
    let href: URL
}

/// An OPDS acquisition entry — a downloadable publication.
struct AcquisitionEntry: Sendable, Equatable, Identifiable {
    var id: String { serverID }

    /// `atom:id` — the primary dedup key against SwiftData `Book.serverID`.
    let serverID: String
    let title: String
    let authors: [String]
    let summary: String?
    let publishedAt: Date?
    /// All available formats. Always non-empty when present.
    let acquisitions: [Acquisition]
    /// `rel="http://opds-spec.org/image/thumbnail"`, resolved.
    let thumbnailURL: URL?
    /// `rel="http://opds-spec.org/image"`, resolved.
    let coverURL: URL?
}

/// One acquisition link on an entry (one format).
struct Acquisition: Sendable, Equatable, Identifiable {
    var id: URL { href }

    let href: URL
    let mimeType: String
    let format: BookFormat
}
