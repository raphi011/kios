import SwiftUI

/// One grouped-inset card per section (Reading / Unread / Finished) when
/// the library is in list mode. Hairlines between rows. The parent supplies
/// the metadata closures so this view stays decoupled from `Book`'s file
/// system + finishedAt formatting.
struct LibraryListSection: View {
    enum Kind { case reading, unread, finished }

    let title: LocalizedStringResource
    let books: [Book]
    let kind: Kind
    var footer: LocalizedStringKey? = nil
    let progressByBookID: [UUID: Double]
    let metaForBook: (Book) -> String?
    let finishedLabelForBook: (Book) -> String?
    let onTap: (Book) -> Void

    var body: some View {
        let localizedName = String(localized: title)
        EditorialList("\(localizedName) · \(books.count)", footer: footer) {
            ForEach(books.indices, id: \.self) { i in
                let book = books[i]
                Button { onTap(book) } label: {
                    EditorialBookRow(
                        title: book.title,
                        author: book.authors.joined(separator: ", "),
                        progress: progressByBookID[book.id] ?? 0,
                        meta: kind == .unread ? metaForBook(book) : nil,
                        finishedLabel: kind == .finished ? finishedLabelForBook(book) : nil
                    ) {
                        AnyView(BookCoverImage(book: book))
                    }
                }
                .buttonStyle(.plain)
                if i < books.count - 1 {
                    EditorialHairline()
                }
            }
        }
    }
}
