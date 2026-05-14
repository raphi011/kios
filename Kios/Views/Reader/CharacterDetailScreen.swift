// Kios/Views/Reader/CharacterDetailScreen.swift
import SwiftUI
import SwiftData

/// Pushed from the Insights sheet's Characters tab. Shows:
///   • Canonical name + aliases header
///   • Description (synthesizedDescription when "full book" toggle is on;
///     concatenated per-chapter descriptions up to the user's current
///     reading position when "spoiler-free" is on)
///   • Chapter-by-chapter mention list with quote previews
///
/// Tapping a mention dismisses the sheet and asks the reader to jump to
/// the quote (Task 24 wires `onJump`).
struct CharacterDetailScreen: View {
    let profileID: UUID
    let bookID: UUID
    let book: Book
    let onJump: (String, String) -> Void   // (chapterHref, quote)
    let onDismissSheet: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [CharacterProfile]
    @Query private var mentions: [CharacterMention]
    @Query private var analyses: [BookAnalysis]
    @State private var showFullBook = false
    @State private var pendingJump: (href: String, quote: String, futureChapter: Int)?

    init(
        profileID: UUID, bookID: UUID, book: Book,
        onJump: @escaping (String, String) -> Void,
        onDismissSheet: @escaping () -> Void
    ) {
        self.profileID = profileID
        self.bookID = bookID
        self.book = book
        self.onJump = onJump
        self.onDismissSheet = onDismissSheet
        _profiles = Query(filter: #Predicate<CharacterProfile> { $0.id == profileID })
        _mentions = Query(
            filter: #Predicate<CharacterMention> {
                $0.bookID == bookID && $0.profileID == profileID
            },
            sort: \.chapterIndex
        )
        _analyses = Query(filter: #Predicate<BookAnalysis> { $0.bookID == bookID })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = profiles.first {
                    header(p)
                    description(p)
                    mentionsList
                }
            }
            .padding(.horizontal, EditorialTheme.rowSidePad)
            .padding(.vertical, 12)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showFullBook.toggle() }) {
                    Text(showFullBook ? "Through what you've read" : "Show full book")
                        .font(EditorialTheme.sans(size: 13, weight: .medium))
                }
            }
        }
        .alert(
            "Past your current position",
            isPresented: Binding(
                get: { pendingJump != nil },
                set: { if !$0 { pendingJump = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingJump = nil }
            Button("Continue") {
                if let j = pendingJump {
                    book.maxChapterIndexReached = max(book.maxChapterIndexReached, j.futureChapter)
                    try? modelContext.save()
                    pendingJump = nil
                    onDismissSheet()
                    onJump(j.href, j.quote)
                }
            }
        } message: {
            Text("This chapter is past your current reading position. Continue?")
        }
    }

    private func header(_ p: CharacterProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.canonicalName)
                .font(EditorialTheme.serif(size: 28, weight: .medium))
                .foregroundStyle(EditorialTheme.ink)
            if !p.allAliases.isEmpty {
                Text("Also known as: \(p.allAliases.joined(separator: ", "))")
                    .font(EditorialTheme.sans(size: 13))
                    .foregroundStyle(EditorialTheme.muted)
            }
        }
    }

    private func description(_ p: CharacterProfile) -> some View {
        Text(renderedDescription(profile: p))
            .font(EditorialTheme.sans(size: 16))
            .foregroundStyle(EditorialTheme.ink)
    }

    private func renderedDescription(profile: CharacterProfile) -> String {
        if showFullBook { return profile.synthesizedDescription }
        let cap = book.maxChapterIndexReached
        let parts = mentions
            .filter { $0.chapterIndex <= cap }
            .map(\.descriptionFromChapter)
        return parts.isEmpty ? "No mentions yet in chapters you've read." : parts.joined(separator: " ")
    }

    private var mentionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapter mentions")
                .editorialEyebrow()
                .padding(.top, 12)
            ForEach(visibleMentions, id: \.id) { m in
                Button(action: { tap(m) }) {
                    mentionRow(m)
                }
                .buttonStyle(.plain)
                EditorialHairline()
            }
        }
    }

    private func mentionRow(_ m: CharacterMention) -> some View {
        let isFuture = m.chapterIndex > book.maxChapterIndexReached
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chapter \(m.chapterIndex + 1)")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(isFuture ? EditorialTheme.muted : EditorialTheme.ink)
                if isFuture && showFullBook {
                    Text("Past your current position")
                        .font(EditorialTheme.mono(size: 10))
                        .foregroundStyle(EditorialTheme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(red: 0.235, green: 0.196, blue: 0.157, opacity: 0.06))
                        .clipShape(Capsule())
                }
            }
            Text("“\(m.quote)”")
                .font(EditorialTheme.serif(size: 13))
                .italic()
                .foregroundStyle(EditorialTheme.muted)
        }
        .padding(.vertical, 8)
        .opacity(isFuture && showFullBook ? 0.6 : 1)
    }

    private var visibleMentions: [CharacterMention] {
        let dataCap = analyses.first?.chaptersCompleted ?? 0
        return mentions.filter { m in
            if showFullBook { return m.chapterIndex < dataCap }
            return m.chapterIndex <= book.maxChapterIndexReached
        }
    }

    private func tap(_ m: CharacterMention) {
        if m.chapterIndex > book.maxChapterIndexReached {
            pendingJump = (m.chapterHref, m.quote, m.chapterIndex)
        } else {
            onDismissSheet()
            onJump(m.chapterHref, m.quote)
        }
    }
}
