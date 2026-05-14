import Foundation

/// Where a Book came from. `.synced` means the catalog (CWA/Kobo) is the
/// authoritative source for identity (serverID, serverIDProtocol,
/// acquisitionURL); `.local` means the user imported the file directly and
/// those catalog fields are nil until the book auto-promotes on a
/// partialMD5 catalog match.
enum BookSource: String, Codable, Sendable {
    case synced
    case local
}
