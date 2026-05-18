import Foundation
import Observation

/// Bridge between App Intents (which run outside the app's DI graph) and
/// SwiftUI navigation. `OpenMostRecentBookIntent.perform()` writes into
/// this object; `RootView` observes `pendingBookID` and routes via
/// `env.router.openReader` when it transitions from `nil` to a real value.
///
/// `consume()` clears the value atomically so `onChange` doesn't re-fire
/// on the same request after navigation settles.
@MainActor
@Observable
final class BookOpenCoordinator {
    /// Shared instance used by App Intent code paths. Test code constructs
    /// its own instance instead.
    static let shared = BookOpenCoordinator()

    var pendingBookID: UUID?

    func request(_ bookID: UUID) {
        pendingBookID = bookID
    }

    func consume() -> UUID? {
        defer { pendingBookID = nil }
        return pendingBookID
    }
}
