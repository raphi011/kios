import Foundation

/// An OPDS catalog feed with its entries.
struct OPDSCatalog: Sendable, Equatable {
    let title: String
    let entries: [OPDSEntry]
    let nextURL: URL?
}

/// A single acquirable publication from an OPDS feed.
struct OPDSEntry: Sendable, Equatable, Identifiable {
    var id: String { serverID }

    /// The identifier from the OPDS entry's `<id>` element.
    let serverID: String
    let title: String
    let authors: [String]
    /// URL to the full entry detail page (rel="self" link on the entry).
    let detailURL: URL?
    /// Direct download URL (rel contains "acquisition").
    let acquisitionURL: URL
    let format: BookFormat
}
