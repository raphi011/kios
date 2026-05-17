import SwiftUI
import UIKit
import Core

/// Shared thumbnail loader. Same source-of-truth branching as `BookRow`'s
/// private thumbnail, lifted to a reusable view so editorial Home / Library
/// rows and the hero card don't each re-implement it.
///
/// - `.local`: read bytes off disk.
/// - server + `.kosync`: OPDS thumbnail behind Basic auth.
/// - server + `.kobo`: pre-signed CDN URL (no Authorization header).
///
/// Layout:
/// - `.fill` (default): `scaledToFill` for list rows / hero where every
///   cell is the same aspect ratio as the cover.
/// - `.matteFit`: `scaledToFit` over a `background(matte)` derived from
///   the cover's average color — for gallery cells where covers' native
///   aspect ratios vary and we want uniform 2:3 cells without cropping.
struct BookCoverImage: View {
    let book: Book
    var style: Style = .fill

    enum Style { case fill, matteFit }

    @Environment(AppEnvironment.self) private var env
    @State private var matte: Color

    init(book: Book, style: Style = .fill) {
        self.book = book
        self.style = style
        let seed: Color = {
            guard style == .matteFit, let url = Self.coverURL(for: book) else {
                return EditorialTheme.bg
            }
            guard let cached = ImageMemoryCache.shared.color(for: url) else {
                return EditorialTheme.bg
            }
            return Color(uiColor: cached)
        }()
        self._matte = State(initialValue: seed)
    }

    var body: some View {
        switch style {
        case .fill:
            inner.scaledToFill()
        case .matteFit:
            inner
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(matte)
        }
    }

    @ViewBuilder
    private var inner: some View {
        if book.source.kind == .local {
            local
        } else if book.serverIDProtocol == SyncProtocol.kosync.rawValue {
            kosync
        } else {
            kobo
        }
    }

    @ViewBuilder
    private var local: some View {
        CachedAsyncImage(
            url: book.coverFileURL,
            onLoad: onCoverLoaded
        ) { placeholder }
    }

    @ViewBuilder
    private var kosync: some View {
        if let creds = try? env.authStore.load() {
            CachedAsyncImage(
                url: book.thumbnailURL,
                http: Core.HTTPClient(credentials: creds.basic),
                onLoad: onCoverLoaded
            ) { placeholder }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var kobo: some View {
        CachedAsyncImage(
            url: book.thumbnailURL,
            onLoad: onCoverLoaded
        ) { placeholder }
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

    private func onCoverLoaded(_ image: UIImage) {
        guard style == .matteFit, let url = Self.coverURL(for: book) else { return }
        if let cached = ImageMemoryCache.shared.color(for: url) {
            let next = Color(uiColor: cached)
            if matte != next { matte = next }
            return
        }
        // Mute toward paper so a vivid cover doesn't oversaturate the wall.
        // 0.35 keeps the cover's identity but pulls highlights into the
        // editorial palette's range.
        guard let raw = image.averageColor() else { return }
        let muted = raw.blended(toward: UIColor(EditorialTheme.bg), by: 0.35)
        ImageMemoryCache.shared.storeColor(muted, for: url)
        matte = Color(uiColor: muted)
    }

    private static func coverURL(for book: Book) -> URL? {
        if book.source.kind == .local {
            return book.coverFileURL
        }
        return book.thumbnailURL
    }
}
