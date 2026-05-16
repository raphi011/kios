import SwiftUI
import Core

/// Hero "Continue reading" card. Bigger cover (88×130) and a stronger serif
/// title than `EditorialBookRow`, with a chapter eyebrow when available and
/// a paired progress bar (% read · time left) at the bottom.
///
/// Chapter text is best-effort — the design's "ch. 4 · platonic fold" eyebrow
/// is only set when we have a chapter title. Otherwise we hide that line.
struct EditorialContinueCard: View {
    let book: Book
    let progress: Double
    let perBookSessions: [ReadingSession]
    /// Best-effort chapter title eyebrow, e.g. "ch. 4 · platonic fold". When
    /// nil, the eyebrow line is omitted (we don't currently track chapters
    /// on the home model).
    var chapterEyebrow: String? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                BookCoverImage(book: book)
                    .frame(width: 88, height: 130)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 4)
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 0) {
                    Text(book.title)
                        .font(EditorialTheme.serif(size: 22, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(EditorialTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !book.authors.isEmpty {
                        Text(book.authors.joined(separator: ", "))
                            .font(EditorialTheme.serif(size: 14))
                            .italic()
                            .foregroundStyle(EditorialTheme.inkSoft)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }

                    if let chapterEyebrow {
                        Text(chapterEyebrow)
                            .editorialEyebrow()
                            .padding(.top, 10)
                    }

                    Spacer(minLength: 12)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(EditorialTheme.progressTrack)
                            Capsule()
                                .fill(EditorialTheme.ink)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)

                    HStack {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(EditorialTheme.mono(size: 11))
                            .foregroundStyle(EditorialTheme.muted)
                        Spacer()
                        if let remaining = remainingLabel {
                            Text(remaining)
                                .font(EditorialTheme.mono(size: 11))
                                .foregroundStyle(EditorialTheme.muted)
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.vertical, 2)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }

    private var remainingLabel: String? {
        guard let estimate = StatsAggregator.paceEstimate(
            bookID: book.id,
            progressFraction: progress,
            book: book,
            sessions: perBookSessions
        ) else { return nil }
        return StatsFormatters.time(seconds: estimate.secondsRemaining) + " left"
    }
}
