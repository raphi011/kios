import SwiftUI
import Core

/// Hero card for the most-recently-touched book. Tapping opens the reader.
/// "X left" estimate uses per-book pace; hidden when the book has no
/// sessions yet (fresh download in the hero).
struct ContinueReadingCard: View {
    let book: Book
    let progress: Double
    let sessions: [ReadingSession]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                BookCoverThumb(book: book)
                    .frame(width: 60, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 6) {
                    Text("CONTINUE READING")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !book.authors.isEmpty {
                        Text(book.authors.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                    HStack(spacing: 6) {
                        Text("\(Int(progress * 100))%")
                            .monospacedDigit()
                        if let remaining = remainingTimeLabel {
                            Text("·")
                            Text(remaining)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// Watermark-anchored pace: hides until per-book trusted reading
    /// reaches 5 minutes; falls back to nil when totalPositions is unknown
    /// (book has never been opened in the reader on this device).
    private var remainingTimeLabel: String? {
        guard let estimate = StatsAggregator.paceEstimate(
            bookID: book.id,
            progressFraction: progress,
            book: book,
            sessions: sessions
        ) else { return nil }
        let formatted = StatsFormatters.time(seconds: estimate.secondsRemaining)
        return String(
            localized: "stats.timeLeft",
            defaultValue: "\(formatted) left"
        )
    }
}

/// Thin wrapper around `BookRow`'s thumbnail logic. Kept inline (vs
/// exposing the private thumbnail from `BookRow`) because the kosync/Kobo
/// branching is small and the call sites are different enough that
/// duplication is cheaper than abstraction.
private struct BookCoverThumb: View {
    let book: Book
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch book.source {
            case .local:
                CachedAsyncImage(url: book.coverFileURL) { placeholder }
                    .scaledToFill()
            case .synced:
                if book.serverIDProtocol == SyncProtocol.kosync.rawValue,
                   let creds = try? env.authStore.load() {
                    CachedAsyncImage(
                        url: book.thumbnailURL,
                        http: Core.HTTPClient(credentials: creds.basic)
                    ) { placeholder }
                        .scaledToFill()
                } else {
                    CachedAsyncImage(url: book.thumbnailURL) { placeholder }
                        .scaledToFill()
                }
            }
        }
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
