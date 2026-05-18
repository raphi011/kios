import SwiftUI

/// Three-column grid of book covers under a tracked-mono eyebrow header.
/// Used by `LibraryRootView`'s gallery mode for each of Reading / Unread /
/// Finished. The parent passes an `onTap` so the row can route into either
/// the reader or the download flow.
struct LibraryGallerySection: View {
    let title: LocalizedStringResource
    let books: [Book]
    let onTap: (Book) -> Void

    var body: some View {
        let localizedName = String(localized: title)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(localizedName) · \(books.count)")
                .editorialEyebrow()
                .padding(.horizontal, EditorialTheme.listSidePad)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                ],
                spacing: 16
            ) {
                ForEach(books, id: \.id) { book in
                    Button { onTap(book) } label: {
                        BookCoverImage(book: book, style: .matteFit)
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, EditorialTheme.listSidePad)
        }
    }
}
