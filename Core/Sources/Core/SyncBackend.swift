import Foundation

public struct BookIdentity: Sendable, Hashable {
    public let partialMD5: String?
    public let koboBookUUID: String?

    public init(partialMD5: String? = nil, koboBookUUID: String? = nil) {
        self.partialMD5 = partialMD5
        self.koboBookUUID = koboBookUUID
    }
}

public struct CanonicalProgress: Sendable, Equatable {
    public let percentage: Double
    public let locatorJSON: String?
    public let timestamp: Date
    public let deviceID: String
    public let deviceName: String

    public init(
        percentage: Double,
        locatorJSON: String?,
        timestamp: Date,
        deviceID: String,
        deviceName: String
    ) {
        self.percentage = percentage
        self.locatorJSON = locatorJSON
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public enum BackendError: Error, Sendable, Equatable {
    case identityMissing(field: String)
    case authenticationFailed
    case serverShapeUnexpected(detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(URLErrorCode)

    /// Wrapper avoiding URLError's non-Equatable conformance.
    public struct URLErrorCode: Sendable, Equatable {
        public let rawValue: Int
        public init(_ urlError: URLError) { self.rawValue = urlError.code.rawValue }
        public init(rawValue: Int) { self.rawValue = rawValue }
    }
}
