import SwiftUI

/// Editorial picker for Settings → Default font. Lists every
/// `ReaderFontFamily` entry as a tappable row that renders the family
/// name in its own typeface, so the user sees what they're choosing
/// before committing. Selection writes to `@AppStorage("reader.fontFamily")`
/// and dismisses; `ReaderView` reads the same key and forwards into
/// Readium's preferences.
struct FontFamilyPickerView: View {
    @AppStorage("reader.fontFamily") private var fontFamily: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EditorialList(footer: "Choose a typeface for all books, or keep \"Publisher default\" to honour each book's own styling.") {
                    ForEach(Array(ReaderFontFamily.allCases.enumerated()), id: \.element.id) { idx, font in
                        Button {
                            fontFamily = font.rawValue
                            dismiss()
                        } label: {
                            FontFamilyRow(
                                font: font,
                                isSelected: font.rawValue == fontFamily
                            )
                        }
                        .buttonStyle(.plain)
                        if idx < ReaderFontFamily.allCases.count - 1 {
                            EditorialHairline()
                        }
                    }
                }

                Color.clear.frame(height: 60)
            }
            .padding(.top, 4)
        }
        .background(EditorialTheme.bg)
        .navigationTitle("Default font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Single row in the font picker. Family name on the left rendered in
/// its own face (so the user previews the choice), checkmark on the
/// right when this row is the active selection.
private struct FontFamilyRow: View {
    let font: ReaderFontFamily
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(font.displayName)
                .font(font.previewFont(size: 19))
                .foregroundStyle(EditorialTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EditorialTheme.accent)
            }
        }
        .padding(.horizontal, EditorialTheme.rowSidePad)
        .padding(.vertical, 14)
        .frame(minHeight: EditorialTheme.cellMin)
        .contentShape(Rectangle())
    }
}
