import Foundation

public enum HTTPError: Swift.Error, LocalizedError, Equatable, Sendable {
    case unauthorized
    case notFound
    case server(status: Int, body: Data)
    case transport(URLError)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized (401). Check username and password."
        case .notFound:     return "Not found (404)."
        case .server(let s, _): return "Server returned status \(s)."
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .malformedResponse: return "Malformed server response."
        }
    }
}
