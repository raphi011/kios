import SwiftUI
import ReadiumShared

/// Modal screen presented from the reader's contents (`⊟`) button. Hosts
/// three tabs — Contents · Bookmarks · Notes — in the editorial design
/// language. Contents is functional (tap a chapter → jump); Bookmarks +
/// Notes are placeholder empty states until those models exist.
struct ReaderContentsView: View {

    // MARK: - Public

    struct Chapter: Identifiable {
        let id = UUID()
        /// 1-based ordinal — drives both the eyebrow ("CHAPTER IV") and the
        /// page-number alignment column on the right.
        let index: Int
        let roman: String
        let title: String
        /// TOC nesting depth, 0 = top-level. Drives row indentation so the
        /// hierarchy of the source TOC reads visually.
        let depth: Int
        /// 1-based page (position) number. Aligned-right column.
        let page: Int
        let status: Status
        /// Jump target. Caller hands it back to the navigator via
        /// `ReaderView.pendingJump`.
        let locator: Locator
    }

    enum Status { case read, current, unread }

    let bookTitle: String
    let chapters: [Chapter]
    /// Tap a chapter row — caller sets `pendingJump` and dismisses.
    let onJump: (Locator) -> Void
    let onDismiss: () -> Void

    // MARK: - Internal state

    private enum Tab: Hashable { case contents, bookmarks, notes }
    @State private var tab: Tab = .contents

    var body: some View {
        VStack(spacing: 0) {
            compactNav
            tabPicker
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                Group {
                    switch tab {
                    case .contents:   contentsTab
                    case .bookmarks:  bookmarksTab
                    case .notes:      notesTab
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(EditorialTheme.bg.ignoresSafeArea())
    }

    // MARK: - Nav

    private var compactNav: some View {
        HStack(spacing: 8) {
            Button(action: onDismiss) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .regular))
                    Text("Reader")
                        .font(EditorialTheme.sans(size: 15, weight: .medium))
                }
                .foregroundStyle(EditorialTheme.accent)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(bookTitle)
                .font(EditorialTheme.serif(size: 16, weight: .medium))
                .italic()
                .foregroundStyle(EditorialTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button(action: { /* search stub — not implemented yet */ }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(EditorialTheme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            EditorialTheme.rule.frame(height: 0.5)
        }
    }

    // MARK: - Tabs

    private var tabPicker: some View {
        EditorialSegmented(
            items: [
                ("Contents · \(chapters.count)", Tab.contents),
                ("Bookmarks · 0", Tab.bookmarks),
                ("Notes · 0", Tab.notes),
            ],
            selection: $tab
        )
    }

    // MARK: - Contents

    @ViewBuilder
    private var contentsTab: some View {
        if chapters.isEmpty {
            emptyState(
                systemImage: "list.bullet",
                title: "No chapters",
                detail: "This book doesn't have a table of contents."
            )
            .padding(.top, 80)
        } else {
            EditorialList(footer: footerForContents) {
                ForEach(chapters.indices, id: \.self) { i in
                    let chapter = chapters[i]
                    Button { onJump(chapter.locator) } label: {
                        ChapterRow(chapter: chapter)
                    }
                    .buttonStyle(.plain)
                    if i < chapters.count - 1 {
                        EditorialHairline()
                    }
                }
            }
        }
    }

    private var footerForContents: LocalizedStringKey? {
        guard let current = chapters.first(where: { $0.status == .current }) else {
            return nil
        }
        return "Chapter \(current.roman) · \(current.title)"
    }

    // MARK: - Empty states (Bookmarks / Notes)

    private var bookmarksTab: some View {
        emptyState(
            systemImage: "bookmark",
            title: "No bookmarks yet",
            detail: "Saving passages from the reader will land here. Coming soon."
        )
        .padding(.top, 80)
    }

    private var notesTab: some View {
        emptyState(
            systemImage: "highlighter",
            title: "No notes yet",
            detail: "Highlights and the notes you take on them will live here. Coming soon."
        )
        .padding(.top, 80)
    }

    private func emptyState(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(EditorialTheme.muted)
            Text(title)
                .font(EditorialTheme.serif(size: 20, weight: .semibold))
                .foregroundStyle(EditorialTheme.ink)
            Text(detail)
                .font(EditorialTheme.serif(size: 14))
                .italic()
                .foregroundStyle(EditorialTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

// MARK: - ChapterRow

/// Single chapter row in the contents list. Title (with optional "You are
/// here" eyebrow) on the left, checkmark + page on the right. Sub-chapters
/// indent by depth and step down a typographic size so the source TOC's
/// hierarchy reads visually. The current chapter gets the `accentSoft`
/// background fill and a 3pt accent-red leading bar.
private struct ChapterRow: View {
    let chapter: ReaderContentsView.Chapter

    private var isCurrent: Bool { chapter.status == .current }
    private var isUnread: Bool  { chapter.status == .unread }
    private var isRead: Bool    { chapter.status == .read }
    private var isSub: Bool     { chapter.depth > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.title)
                    .font(EditorialTheme.serif(
                        size: isSub ? 14 : 16,
                        weight: isCurrent ? .semibold : .medium
                    ))
                    .foregroundStyle(isUnread ? EditorialTheme.inkSoft : EditorialTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if isCurrent {
                    Text("You are here")
                        .editorialEyebrow(color: EditorialTheme.accent)
                }
            }
            .padding(.leading, CGFloat(chapter.depth) * 18)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if isRead {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(EditorialTheme.muted)
                }
                Text(String(chapter.page))
                    .font(EditorialTheme.mono(size: 11))
                    .tracking(0.2)
                    .foregroundStyle(EditorialTheme.muted)
            }
        }
        .padding(.horizontal, EditorialTheme.rowSidePad)
        .padding(.vertical, isSub ? 10 : 14)
        .frame(minHeight: isSub ? 44 : 56)
        .background(isCurrent ? EditorialTheme.accentSoft : Color.clear)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(EditorialTheme.accent)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }
}
