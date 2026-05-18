import Foundation

public struct BasicCredentials: Sendable, Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var authorizationHeader: String {
        let raw = "\(username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }
}

public struct HTTPClient: Sendable {
    private let session: URLSession
    private let credentials: BasicCredentials?

    public init(session: URLSession = .shared, credentials: BasicCredentials? = nil) {
        self.session = session
        self.credentials = credentials
    }

    @discardableResult
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let credentials {
            req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.malformedResponse
            }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401:       throw HTTPError.unauthorized
            case 404:       throw HTTPError.notFound
            default:        throw HTTPError.server(status: http.statusCode, body: data)
            }
        } catch let urlError as URLError {
            throw HTTPError.transport(urlError)
        }
    }
}
