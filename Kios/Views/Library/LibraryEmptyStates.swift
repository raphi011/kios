import SwiftUI

/// Full-tab empty state shown when the active source has zero books at all.
/// Adds the editorial nav bar + add button on top so the user has the same
/// path to import as in the populated state.
struct LibraryEmptyState: View {
    let onAddTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorialNavBar(titleContent: { SourcePickerHeader() }) {
                EditorialNavIconButton(
                    systemName: "plus",
                    accessibilityLabel: "Add book"
                ) {
                    onAddTap()
                }
            }
            Spacer()
            ContentUnavailableView(
                "Your library is empty",
                systemImage: "books.vertical",
                description: Text("Tap + to import an EPUB, or pull to refresh.")
            )
            Spacer()
        }
    }
}

/// Per-filter empty state shown when the source has books but the active
/// segmented filter produces zero rows. Copy + symbol are driven by the
/// filter so the user understands *why* it's empty.
struct LibraryFilteredEmptyState: View {
    let filter: LibraryFilter

    var body: some View {
        let (title, description, symbol) = Self.copy(for: filter)
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(description)
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.bottom, 80)
    }

    private static func copy(
        for filter: LibraryFilter
    ) -> (title: LocalizedStringKey, description: LocalizedStringKey, symbol: String) {
        switch filter {
        case .all:
            return ("Your library is empty",
                    "Tap + to import an EPUB, or pull to refresh.",
                    "books.vertical")
        case .reading:
            return ("Nothing in progress",
                    "Books you start reading will appear here.",
                    "book.pages")
        case .unread:
            return ("No unread books",
                    "Books you haven't started will appear here.",
                    "book.closed")
        case .finished:
            return ("No finished books",
                    "Books you finish reading will appear here.",
                    "checkmark.circle")
        }
    }
}

/// Compact "no matches for query" state shown when search is active and
/// the result set is empty. Distinct from the per-filter empty state
/// because the copy references the query string.
struct LibrarySearchEmptyState: View {
    let query: String

    var body: some View {
        ContentUnavailableView(
            "No matches",
            systemImage: "magnifyingglass",
            description: Text("Nothing in your library matches \u{201C}\(query)\u{201D}.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
