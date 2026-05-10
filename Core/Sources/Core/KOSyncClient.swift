import Foundation

/// Reading-progress upload payload sent to the kosync server.
public struct ProgressUpload: Codable, Sendable, Equatable {
    public let document: String     // 32-hex partial_md5_checksum
    public let progress: String     // chapter index + intra-chapter progression
    public let percentage: Double   // 0.0...1.0 over the whole book
    public let device: String       // human-readable device name
    public let deviceID: String     // stable per-install UUID

    public init(
        document: String, progress: String, percentage: Double,
        device: String, deviceID: String
    ) {
        self.document = document
        self.progress = progress
        self.percentage = percentage
        self.device = device
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device
        case deviceID = "device_id"
    }
}

/// Reading-progress payload returned by the kosync server.
public struct ProgressDownload: Codable, Sendable, Equatable {
    public let document: String
    public let progress: String
    public let percentage: Double
    public let device: String
    public let deviceID: String
    public let timestamp: TimeInterval?

    public init(
        document: String,
        progress: String,
        percentage: Double,
        device: String,
        deviceID: String,
        timestamp: TimeInterval?
    ) {
        self.document = document
        self.progress = progress
        self.percentage = percentage
        self.device = device
        self.deviceID = deviceID
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device, timestamp
        case deviceID = "device_id"
    }
}

/// Client for the KOReader sync ("kosync") protocol. See `docs/research.md` §2.1
/// for the wire format. Compatible with both the official kosync server and
/// Calibre-Web-Automated's `/kosync` endpoint (which accepts standard
/// HTTP Basic auth via `HTTPClient.credentials`).
public struct KOSyncClient: Sendable {
    public let baseURL: URL
    public let http: HTTPClient

    private static let acceptHeader = "application/vnd.koreader.v1+json"

    public init(baseURL: URL, http: HTTPClient) {
        self.baseURL = baseURL
        self.http = http
    }

    /// Verifies the credentials carried by `http` against `GET /users/auth`.
    /// Returns true on 200; throws `HTTPError.unauthorized` on 401.
    public func authenticate() async throws -> Bool {
        let req = makeRequest(path: "/users/auth", method: "GET")
        _ = try await http.data(for: req)
        return true
    }

    /// Uploads progress for a document. Last-write-wins by server timestamp.
    public func putProgress(_ upload: ProgressUpload) async throws {
        var req = makeRequest(path: "/syncs/progress", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(upload)
        _ = try await http.data(for: req)
    }

    /// Returns the latest progress for `documentHash`, or nil if the server
    /// has no record for it (404).
    public func getProgress(documentHash: String) async throws -> ProgressDownload? {
        let escaped = documentHash.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? documentHash
        let req = makeRequest(path: "/syncs/progress/\(escaped)", method: "GET")
        do {
            let (data, _) = try await http.data(for: req)
            return try JSONDecoder().decode(ProgressDownload.self, from: data)
        } catch HTTPError.notFound {
            return nil
        }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        return req
    }
}
