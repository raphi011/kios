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

private struct KoboContributor: Decodable {
    let name: String
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

public extension KeyedDecodingContainer {
    /// Decodes a `Contributors` field that is either a list of strings or a
    /// list of `{Name: "..."}` objects. Returns `[]` if absent or null.
    func decodeContributors(forKey key: Key) throws -> [String] {
        guard contains(key), try decodeNil(forKey: key) == false else { return [] }
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }
        let objects = try decode([KoboContributor].self, forKey: key)
        return objects.map(\.name)
    }
}

public enum KoboSyncEntry: Sendable {
    case newEntitlement(KoboEntitlement)
    case changedEntitlement(KoboEntitlement)
    case changedReadingState(KoboReadingState)
    case newTag       // ignored content
    case changedTag   // ignored content
    case deletedTag   // ignored content
}

public struct KoboEntitlement: Sendable {
    public let bookEntitlement: KoboBookEntitlement
    public let bookMetadata: KoboBookMetadata
    public let readingState: KoboReadingState?
}

public struct KoboBookEntitlement: Codable, Sendable {
    public let id: String
    public let crossRevisionId: String
    public let revisionId: String
    public let accessibility: String
    public let status: String
    public let isRemoved: Bool
    public let created: String
    public let lastModified: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case crossRevisionId = "CrossRevisionId"
        case revisionId = "RevisionId"
        case accessibility = "Accessibility"
        case status = "Status"
        case isRemoved = "IsRemoved"
        case created = "Created"
        case lastModified = "LastModified"
    }
}

public struct KoboBookMetadata: Sendable {
    public let entitlementId: String
    public let title: String
    public let contributors: [String]
    public let coverImageId: String?
    public let language: String?
    public let description: String?
    public let downloadUrls: [KoboDownloadURL]
}

extension KoboBookMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case entitlementId = "EntitlementId"
        case title = "Title"
        case coverImageId = "CoverImageId"
        case language = "Language"
        case description = "Description"
        case downloadUrls = "DownloadUrls"
        case contributors = "Contributors"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entitlementId = try c.decode(String.self, forKey: .entitlementId)
        title = try c.decode(String.self, forKey: .title)
        coverImageId = try c.decodeIfPresent(String.self, forKey: .coverImageId)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        downloadUrls = try c.decodeIfPresent([KoboDownloadURL].self, forKey: .downloadUrls) ?? []
        contributors = try c.decodeContributors(forKey: .contributors)
    }
}

public struct KoboDownloadURL: Codable, Sendable, Equatable {
    public let format: String   // "KEPUB" | "EPUB" | "EPUB3" | "EPUB3FL"
    public let url: URL
    public let size: Int?
    public let platform: String?

    enum CodingKeys: String, CodingKey {
        case format = "Format", url = "Url", size = "Size", platform = "Platform"
    }
}

extension KoboEntitlement: Decodable {
    enum CodingKeys: String, CodingKey {
        case bookEntitlement = "BookEntitlement"
        case bookMetadata = "BookMetadata"
        case readingState = "ReadingState"
    }
}

/// Wrapper that decodes as nil for non-dict / unknown-shape entries.
/// Use `[KoboSyncEntryOrSkip].self` when decoding the sync array, then
/// `.compactMap { $0.entry }`.
public struct KoboSyncEntryOrSkip: Decodable, Sendable {
    public let entry: KoboSyncEntry?

    private struct ChangedReadingStateWrapper: Decodable {
        let readingState: KoboReadingState
        enum CodingKeys: String, CodingKey { case readingState = "ReadingState" }
    }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: SyncEntryKey.self),
              let key = container.allKeys.first else {
            entry = nil
            return
        }
        switch key.stringValue {
        case "NewEntitlement":
            entry = .newEntitlement(try container.decode(KoboEntitlement.self, forKey: key))
        case "ChangedEntitlement":
            entry = .changedEntitlement(try container.decode(KoboEntitlement.self, forKey: key))
        case "ChangedReadingState":
            entry = .changedReadingState(
                try container.decode(ChangedReadingStateWrapper.self, forKey: key).readingState
            )
        case "NewTag":      entry = .newTag
        case "ChangedTag":  entry = .changedTag
        case "DeletedTag":  entry = .deletedTag
        default:            entry = nil
        }
    }
}

private struct SyncEntryKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}
