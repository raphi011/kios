import SwiftUI
import Core

/// Unified row used by Home and Library. Renders a thumbnail, title/authors,
/// a format chip, and a trailing status area that adapts to the book's state:
///
/// - Downloaded + reading progress > 0 → progress bar + percent
/// - Downloaded + no progress yet     → blank trailing area
/// - Catalog-only (not yet downloaded) → cloud-download icon
///
/// Thumbnail loading branches first on `book.source`: `.local` reads bytes
/// from disk via `coverFileURL`; `.synced` then branches on `serverIDProtocol`
/// because kosync thumbnails require Basic auth (Calibre-Web OPDS) while Kobo
/// serves pre-signed CDN URLs that reject any Authorization header.
struct BookRow: View {
    let book: Book
    /// 0...1. Ignored for catalog-only books. Pass 0 if unknown.
    let readingProgress: Double

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    FormatChip(format: book.format)
                    if book.filename != nil, readingProgress > 0 {
                        ProgressView(value: min(max(readingProgress, 0), 1))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 120)
                        Text("\(Int(readingProgress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            if book.filename == nil {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Not downloaded")
            }
        }
        .contentShape(Rectangle())
    }

    /// Hardcoded 2:3 dimensions matching the Apple Books / Kindle / Libby
    /// pattern — the cover anchors the row height rather than trying to derive
    /// its size from sibling text. `scaledToFill + clipped` fills the rounded
    /// rect even if a particular cover deviates slightly from 2:3.
    @ViewBuilder
    private var thumbnail: some View {
        Group {
            switch book.source {
            case .local:
                localThumbnail
            case .synced:
                if book.serverIDProtocol == SyncProtocol.kosync.rawValue {
                    kosyncThumbnail
                } else {
                    koboThumbnail
                }
            }
        }
        .frame(width: 56, height: 84)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var localThumbnail: some View {
        CachedAsyncImage(url: book.coverFileURL) { placeholder }
            .scaledToFill()
    }

    @ViewBuilder
    private var kosyncThumbnail: some View {
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
    private var koboThumbnail: some View {
        CachedAsyncImage(url: book.thumbnailURL) { placeholder }
            .scaledToFill()
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                Image(systemName: "book.closed")
                    .resizable().scaledToFit()
                    .padding(10)
                    .foregroundStyle(.secondary)
            }
    }
}

private struct FormatChip: View {
    let format: BookFormat

    var body: some View {
        Text(format.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            )
            .foregroundStyle(.secondary)
    }
}
