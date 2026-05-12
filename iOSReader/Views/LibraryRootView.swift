import SwiftUI
import SwiftData
import UIKit
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

    @State private var isRefreshing: Bool = false

    var body: some View {
        NavigationStack {
            // Always render a List so `.refreshable` has a scrollable parent —
            // the empty state goes inside as an overlay. ContentUnavailableView
            // alone is not scrollable and the pull-to-refresh gesture silently
            // does nothing.
            List(books) { book in
                Button { handleTap(book) } label: {
                    LibraryBookRow(book: book)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if books.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "books.vertical",
                        description: Text("Pull to refresh, or tap Refresh.")
                    )
                }
            }
            .refreshable {
                try? await env.refreshLibrary()
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            isRefreshing = true
                            try? await env.refreshLibrary()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh library")
                }
            }
        }
    }

    private func handleTap(_ book: Book) {
        if book.filename != nil {
            env.openReader(book.id)
            return
        }
        // Catalog-only — kick off a download. The reader shows a downloading
        // state until the file lands. For Kobo we first try to refresh the
        // pre-signed CDN URL through the catalog backend, since the one we
        // captured at listLibrary time may have expired.
        Task {
            if book.serverIDProtocol == SyncProtocol.kobo.rawValue {
                await refreshKoboDownloadURL(for: book)
            }
            _ = try? await env.downloads?.download(book: book)
        }
        env.openReader(book.id)
    }

    /// Re-resolves `book.acquisitionURL` via the catalog backend. Kobo serves
    /// pre-signed CDN URLs with a finite TTL, and the URL captured at
    /// listLibrary time may have expired by the time the user taps. The
    /// current `KoboBackend.resolveDownload` is a pass-through, so today this
    /// is future-proofing for the CWA-side refresh hook. Errors are swallowed
    /// on purpose — if resolution fails we let the download attempt the stale
    /// URL and surface a real download error rather than blocking on the
    /// refresh.
    private func refreshKoboDownloadURL(for book: Book) async {
        do {
            let name = await UIDevice.current.name
            let (_, catalog) = try BackendFactory.build(
                auth: env.authStore, deviceID: env.deviceID, deviceName: name
            )
            let entry = CatalogEntry(
                serverID: book.serverID,
                title: book.title,
                authors: book.authors,
                identity: book.identity,
                downloadURL: book.acquisitionURL,
                format: book.format,
                thumbnailURL: book.thumbnailURL
            )
            let fresh = try await catalog.resolveDownload(for: entry)
            book.acquisitionURL = fresh
            try? context.save()
        } catch {
            // Intentional fall-through — see doc comment above.
        }
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
