import Foundation

enum DownloadState: String, Codable, Sendable {
    case idle
    case running
    case completed
    case failed
}
