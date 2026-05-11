import Foundation

public enum BookFormat: String, Codable, Sendable, CaseIterable {
    case epub
    case pdf
    case cbz

    public init?(mimeType: String) {
        switch mimeType.lowercased() {
        case "application/epub+zip": self = .epub
        case "application/pdf":       self = .pdf
        case "application/x-cbz", "application/vnd.comicbook+zip": self = .cbz
        default: return nil
        }
    }

    public var fileExtension: String { rawValue }
}
