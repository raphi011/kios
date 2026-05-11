import Foundation

/// Resources block returned by CWA's `/kobo/{token}/v1/initialization` endpoint.
/// `image_url_template` is the only field we currently consume — it carries the
/// cover-image URL pattern with `{ImageId}`, `{width}`, `{height}` placeholders.
public struct KoboInitResources: Sendable, Codable {
    public let imageURLTemplate: String

    public init(imageURLTemplate: String) {
        self.imageURLTemplate = imageURLTemplate
    }

    enum CodingKeys: String, CodingKey { case imageURLTemplate = "image_url_template" }
}

/// Client for Calibre-Web-Automated's Kobo blueprint endpoints. The user's sync
/// token is baked into `baseURL` (e.g. `https://cwa/kobo/<token>`); requests do
/// not need additional auth headers.
public struct KoboClient: Sendable {
    public let baseURL: URL
    public let http: HTTPClient

    public init(baseURL: URL, http: HTTPClient) {
        self.baseURL = baseURL
        self.http = http
    }

    /// `GET /v1/initialization` — returns the Resources block (image URL
    /// template etc.) the Kobo client uses to construct subsequent requests.
    public func initialization() async throws -> KoboInitResources {
        let url = baseURL.appendingPathComponent("v1/initialization")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, _) = try await http.data(for: req)
        struct Envelope: Decodable {
            let resources: KoboInitResources
            enum CodingKeys: String, CodingKey { case resources = "Resources" }
        }
        return try KoboDecoder.decode(Envelope.self, from: data).resources
    }
}

/// Result of one full `librarySync` call — entries aggregated across any
/// continuation pages, plus the latest synctoken to persist for next time.
public struct KoboLibrarySyncResult: Sendable {
    public let entries: [KoboSyncEntry]
    public let nextSyncToken: String?

    public init(entries: [KoboSyncEntry], nextSyncToken: String?) {
        self.entries = entries
        self.nextSyncToken = nextSyncToken
    }
}

public extension KoboClient {
    /// `GET /v1/library/sync` — paginated incremental sync of the user's
    /// library. The server signals continuation via the `x-kobo-sync` header
    /// (`"continue"` means call again) and threads cursor state through
    /// `x-kobo-synctoken`. Pass the previously persisted token (or `nil` on
    /// first sync); the returned `nextSyncToken` should be persisted for the
    /// next invocation.
    func librarySync(syncToken: String?) async throws -> KoboLibrarySyncResult {
        var allEntries: [KoboSyncEntry] = []
        var token = syncToken
        var pages = 0

        while true {
            pages += 1
            if pages > Self.maxSyncPages {
                throw BackendError.serverShapeUnexpected(
                    detail: "library sync exceeded \(Self.maxSyncPages) pages"
                )
            }

            let url = baseURL.appendingPathComponent("v1/library/sync")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if let token { req.setValue(token, forHTTPHeaderField: "x-kobo-synctoken") }
            let (data, response) = try await http.data(for: req)
            guard let httpResp = response as? HTTPURLResponse else {
                throw BackendError.serverShapeUnexpected(detail: "not http response")
            }

            let pageEntries = try KoboDecoder.decode([KoboSyncEntryOrSkip].self, from: data)
                .compactMap { $0.entry }
            allEntries.append(contentsOf: pageEntries)

            token = httpResp.value(forHTTPHeaderField: "x-kobo-synctoken") ?? token
            let cont = httpResp.value(forHTTPHeaderField: "x-kobo-sync") ?? ""
            if cont != "continue" { break }
        }
        return KoboLibrarySyncResult(entries: allEntries, nextSyncToken: token)
    }

    /// Defense-in-depth against a server that keeps signalling "continue"
    /// indefinitely. A normal CWA library fits well under 100 paginated
    /// requests; anything past this is a server bug or a hostile response.
    static var maxSyncPages: Int { 100 }
}

public extension KoboClient {
    /// `GET /v1/library/<uuid>/state` — returns the current reading state for
    /// a single book, or `nil` if the server responds 404 (book unknown / no
    /// state recorded yet).
    func fetchState(bookUUID: String) async throws -> KoboReadingState? {
        let url = baseURL.appendingPathComponent("v1/library/\(bookUUID)/state")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (data, _) = try await http.data(for: req)
            let states = try KoboDecoder.decode([KoboReadingState].self, from: data)
            return states.first
        } catch HTTPError.notFound {
            return nil
        }
    }

    /// `PUT /v1/library/<uuid>/state` — pushes one or more reading-state
    /// updates (bookmark, status, statistics) for a book. The server's
    /// `UpdateResults` envelope is currently ignored; surface failures via
    /// the underlying HTTPError status.
    func pushState(bookUUID: String, update: KoboStateUpdate) async throws {
        let url = baseURL.appendingPathComponent("v1/library/\(bookUUID)/state")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(update)
        _ = try await http.data(for: req)
    }
}
