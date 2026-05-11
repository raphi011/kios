import Foundation

public enum KoboReadingStatus: String, Codable, Sendable {
    case reading = "Reading"
    case finished = "Finished"
    case readyToRead = "ReadyToRead"
}

public struct KoboLocation: Codable, Sendable, Equatable {
    public let value: String
    public let type: String
    public let source: String

    enum CodingKeys: String, CodingKey { case value = "Value", type = "Type", source = "Source" }
}

public struct KoboCurrentBookmark: Codable, Sendable, Equatable {
    public let lastModified: String
    public let progressPercent: Double?
    public let contentSourceProgressPercent: Double?
    public let location: KoboLocation?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case progressPercent = "ProgressPercent"
        case contentSourceProgressPercent = "ContentSourceProgressPercent"
        case location = "Location"
    }
}

public struct KoboStatusInfo: Codable, Sendable, Equatable {
    public let lastModified: String
    public let status: KoboReadingStatus
    public let timesStartedReading: Int
    public let lastTimeStartedReading: String?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case status = "Status"
        case timesStartedReading = "TimesStartedReading"
        case lastTimeStartedReading = "LastTimeStartedReading"
    }
}

public struct KoboStatistics: Codable, Sendable, Equatable {
    public let lastModified: String
    public let spentReadingMinutes: Int?
    public let remainingTimeMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case spentReadingMinutes = "SpentReadingMinutes"
        case remainingTimeMinutes = "RemainingTimeMinutes"
    }
}

public struct KoboReadingState: Codable, Sendable, Equatable {
    public let entitlementId: String
    public let created: String
    public let lastModified: String
    public let priorityTimestamp: String
    public let statusInfo: KoboStatusInfo?
    public let statistics: KoboStatistics?
    public let currentBookmark: KoboCurrentBookmark?

    enum CodingKeys: String, CodingKey {
        case entitlementId = "EntitlementId"
        case created = "Created"
        case lastModified = "LastModified"
        case priorityTimestamp = "PriorityTimestamp"
        case statusInfo = "StatusInfo"
        case statistics = "Statistics"
        case currentBookmark = "CurrentBookmark"
    }
}

/// Shared decoder configured for CWA's Kobo blueprint timestamp shape.
public enum KoboDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}
