import SwiftUI
import Core

/// Shared thumbnail loader. Same source-of-truth branching as `BookRow`'s
/// private thumbnail, lifted to a reusable view so editorial Home / Library
/// rows and the hero card don't each re-implement it.
///
/// - `.local`: read bytes off disk.
/// - `.synced` + `.kosync`: OPDS thumbnail behind Basic auth.
/// - `.synced` + `.kobo`: pre-signed CDN URL (no Authorization header).
///
/// Caller sets the frame; this view fills it (`scaledToFill + clipped`).
struct BookCoverImage: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch book.source {
            case .local:
                local
            case .synced:
                if book.serverIDProtocol == SyncProtocol.kosync.rawValue {
                    kosync
                } else {
                    kobo
                }
            }
        }
    }

    @ViewBuilder
    private var local: some View {
        CachedAsyncImage(url: book.coverFileURL) { placeholder }
            .scaledToFill()
    }

    @ViewBuilder
    private var kosync: some View {
        if let creds = try? env.authStore.load() {
            CachedAsyncImage(
                url: book.thumbnailURL,
                http: Core.HTTPClient(credentials: creds.basic)
            ) { placeholder }
                .scaledToFill()
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var kobo: some View {
        CachedAsyncImage(url: book.thumbnailURL) { placeholder }
            .scaledToFill()
    }

    private var placeholder: some View {
        // Editorial fallback cover: ink field, accent dot, paper-toned author
        // sticker on top. Keeps the editorial feel even when the cover image
        // hasn't downloaded yet.
        ZStack(alignment: .bottomTrailing) {
            EditorialTheme.ink
            VStack(alignment: .leading, spacing: 4) {
                Text(authorSurname.uppercased())
                    .font(EditorialTheme.sans(size: 7, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color(white: 0.85, opacity: 0.85))
                Text(book.title)
                    .font(EditorialTheme.serif(size: 9, weight: .semibold))
                    .italic()
                    .foregroundStyle(EditorialTheme.bg)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(6)
            Circle()
                .fill(EditorialTheme.accent)
                .frame(width: 5, height: 5)
                .padding(6)
        }
    }

    /// Last word of the first listed author, or "—" when unavailable.
    private var authorSurname: String {
        guard let firstAuthor = book.authors.first,
              let surname = firstAuthor.split(separator: " ").last else {
            return "—"
        }
        return String(surname)
    }
}
