import Foundation

/// Single source of truth for app-managed directories.
///
/// The iOS app container UUID can change across reinstalls and certain redeploys,
/// so absolute file URLs must NOT be persisted. Instead we persist filenames and
/// resolve them through `AppPaths` on each access, which always picks up the
/// current container's `applicationSupportDirectory`.
enum AppPaths {
    /// `<applicationSupport>/kios/books`. Created on first access.
    static var booksDirectory: URL {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("kios/books")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }
}

extension AppPaths {
    /// Filename within `booksDirectory` for a local book's cover image.
    /// Always lowercase `.cover.jpg`; the suffix doubles as the format
    /// declaration. Parallel to `<UUID>.epub` for the book file itself.
    static func coverFilename(for bookUUID: UUID) -> String {
        "\(bookUUID.uuidString).cover.jpg"
    }
}
