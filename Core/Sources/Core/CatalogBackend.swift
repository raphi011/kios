import Foundation

public struct CatalogEntry: Sendable, Equatable {
    public let serverID: String
    public let title: String
    public let authors: [String]
    public let identity: BookIdentity
    public let downloadURL: URL
    public let format: BookFormat
    public let thumbnailURL: URL?

    public init(
        serverID: String,
        title: String,
        authors: [String],
        identity: BookIdentity,
        downloadURL: URL,
        format: BookFormat,
        thumbnailURL: URL?
    ) {
        self.serverID = serverID
        self.title = title
        self.authors = authors
        self.identity = identity
        self.downloadURL = downloadURL
        self.format = format
        self.thumbnailURL = thumbnailURL
    }
}

public protocol CatalogBackend: Sendable {
    /// Cheap reachability + auth check. Throws if the source is not usable.
    /// Used by `AppEnvironment.addSource` before persisting any state.
    func probe() async throws
    func listLibrary() async throws -> [CatalogEntry]
    func resolveDownload(for entry: CatalogEntry) async throws -> URL
}
