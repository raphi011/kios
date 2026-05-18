import Foundation

/// OpenSearch description with a URL template that substitutes a `{searchTerms}` placeholder.
/// Used by `OPDSClient` to issue server-side searches when a feed exposes `rel="search"`.
public struct OpenSearchDescriptor: Sendable, Equatable {
    public let templateURL: URL

    public init(templateURL: URL) {
        self.templateURL = templateURL
    }

    /// Substitutes `{searchTerms}` with a percent-encoded `query`. Returns `nil` if the
    /// template has no placeholder or `query` is empty after whitespace trimming.
    public func resolve(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let raw = templateURL.absoluteString
        // URL automatically percent-encodes { and } as %7B and %7D
        guard raw.contains("%7BsearchTerms%7D") else { return nil }

        let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
        ) ?? trimmed
        let substituted = raw.replacingOccurrences(of: "%7BsearchTerms%7D", with: encoded)
        return URL(string: substituted)
    }
}
