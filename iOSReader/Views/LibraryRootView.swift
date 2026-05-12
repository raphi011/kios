import SwiftUI
import SwiftData
import Core

/// Unified catalog view across sync protocols. Backed by the local
/// SwiftData `Book` store (populated by `LibraryService.refresh`), so the
/// list works identically for kosync and Kobo and is visible offline.
/// Pull-to-refresh re-runs the active protocol's catalog fetch.
struct LibraryRootView: View {
    @Query(filter: #Predicate<Book> { !$0.archived },
           sort: \Book.title)
    private var books: [Book]

    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var env

    @State private var unsupportedKoboAlert: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "books.vertical",
                        description: Text("Pull to refresh, or sign in via Settings.")
                    )
                } else {
                    List(books) { book in
                        Button { handleTap(book) } label: {
                            LibraryBookRow(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Library")
            .refreshable {
                try? await env.refreshLibrary()
            }
            .alert("Kobo reading not yet supported",
                   isPresented: $unsupportedKoboAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This book is from a Kobo sync. The reader doesn't open KEPUB in v1 — the library list is populated for cross-device sync verification only.")
            }
        }
    }

    private func handleTap(_ book: Book) {
        if book.filename != nil {
            env.openReader(book.id)
            return
        }
        // Catalog-only — try to download.
        if book.serverIDProtocol == SyncProtocol.kobo.rawValue {
            unsupportedKoboAlert = true
            return
        }
        // kosync path — kick off download and open the reader. The reader
        // shows a downloading state until the file lands.
        Task { _ = try? await env.downloads?.download(book: book) }
        env.openReader(book.id)
    }
}

/// Row layout used by `LibraryRootView`. Distinct from `HomeBookRow` because
/// Library lists both downloaded and catalog-only books, so it shows a
/// download-state indicator instead of reading progress.
private struct LibraryBookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            statusIcon
        }
        .contentShape(Rectangle())
    }

    /// kosync thumbnails are OPDS-served and require Basic auth, so we route
    /// them through `AuthenticatedAsyncImage` like Home does. Kobo thumbnails
    /// are pre-signed public CDN URLs (template substitution from
    /// `imageURLTemplate`), so plain `AsyncImage` is sufficient — and using
    /// `AuthenticatedAsyncImage` for them would still work but require
    /// loading kosync credentials that may not exist in Kobo mode.
    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if book.serverIDProtocol == SyncProtocol.kosync.rawValue {
                kosyncThumbnail
            } else {
                koboThumbnail
            }
        }
        .frame(width: 44, height: 64)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @Environment(AppEnvironment.self) private var env

    @ViewBuilder
    private var kosyncThumbnail: some View {
        if let creds = try? env.authStore.load() {
            AuthenticatedAsyncImage(
                url: book.thumbnailURL,
                http: Core.HTTPClient(credentials: creds.basic)
            ) {
                placeholder
            }
            .scaledToFill()
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var koboThumbnail: some View {
        if let url = book.thumbnailURL {
            AsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "book.closed")
                    .resizable().scaledToFit()
                    .padding(8)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if book.filename != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not downloaded")
        }
    }
}
