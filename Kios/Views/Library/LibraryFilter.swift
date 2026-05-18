import Foundation

/// Library tab filter — drives both the segmented control and the
/// reading/unread/finished section visibility. Extracted from
/// `LibraryRootView` so the classifier + empty-state helpers can reference
/// it without depending on the view.
enum LibraryFilter: Hashable {
    case all, reading, unread, finished
}

/// Classifies a set of books into the three Library tab buckets. Pure
/// function: takes only the inputs it needs, returns the same shape every
/// time. Lives outside the view so it's unit-testable.
enum LibraryClassifier {

    /// Books with progress strictly between 0 and 1, downloaded, and not
    /// finished. "I'm in the middle of this."
    static func reading(_ books: [Book], progressByBookID: [UUID: Double]) -> [Book] {
        books.filter { book in
            let p = progressByBookID[book.id] ?? 0
            return book.finishedAt == nil && book.filename != nil && p > 0 && p < 1
        }
    }

    /// Books with no progress (downloaded but unstarted) AND catalog-only
    /// books (no filename). Both belong here so the user can see "what's
    /// available to read."
    static func unread(_ books: [Book], progressByBookID: [UUID: Double]) -> [Book] {
        books.filter { book in
            let p = progressByBookID[book.id] ?? 0
            return book.finishedAt == nil && p == 0
        }
    }

    /// Books with a `finishedAt` timestamp (auto-set at ≥95% progression
    /// or manually flagged via the row's context menu).
    static func finished(_ books: [Book]) -> [Book] {
        books.filter { $0.finishedAt != nil }
    }
}
