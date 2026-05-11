import Foundation

/// Single source of truth for app-managed directories.
///
/// The iOS app container UUID can change across reinstalls and certain redeploys,
/// so absolute file URLs must NOT be persisted. Instead we persist filenames and
/// resolve them through `AppPaths` on each access, which always picks up the
/// current container's `applicationSupportDirectory`.
enum AppPaths {
    /// `<applicationSupport>/ios-reader/books`. Created on first access.
    static var booksDirectory: URL {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("ios-reader/books")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
