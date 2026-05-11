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
