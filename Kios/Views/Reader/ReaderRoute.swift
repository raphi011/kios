import Foundation

/// Identifiable wrapper so `fullScreenCover(item:)` can key off the active book.
/// `UUID` is `Hashable` but not `Identifiable`; this struct fills that gap.
struct ReaderRoute: Identifiable, Hashable {
    let id: UUID
}
