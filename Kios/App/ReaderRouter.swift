import Foundation

/// Owns the app-wide reader-presentation state. Drives the `.fullScreenCover`
/// in `RootView` and is set/cleared by anything that opens or closes a book
/// (Home, Library, OpenURL, the Continue Reading App Intent).
///
/// Extracted from `AppEnvironment` so navigation is testable without standing
/// up the full env (SwiftData, Keychain, etc.).
@MainActor
@Observable
final class ReaderRouter {
    /// Set when a reader is open. Hoisted above `TabView` so both Home and
    /// Library can present without double-stacking modals.
    var activeReader: ReaderRoute?

    /// Opens the reader for `bookID`. No-op when a reader is already open.
    func openReader(_ bookID: UUID) {
        guard activeReader == nil else { return }
        activeReader = ReaderRoute(id: bookID)
    }
}
