import SwiftUI
import ReadiumShared

// MARK: - Top bar

/// Editorial reader top bar. A floating Liquid Glass pill inset from the
/// screen edges, with three slots:
///
/// - leading: `‹ Library` back action (accent red)
/// - center: serif book title (truncates to a max width)
/// - trailing: bookmark toggle (`bookmark`/`bookmark.fill`)
///
/// Contents access lives on the bottom bar's chapter row — tap there to
/// open the TOC. The top bar intentionally does not duplicate that.
struct EditorialReaderTopBar: View {
    let title: String
    var onLibrary: () -> Void
    var isBookmarked: Bool
    var onToggleBookmark: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? EditorialTheme.bg : EditorialTheme.ink }
    private var muted: Color { dark ? EditorialTheme.muted.opacity(0.8) : EditorialTheme.muted }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onLibrary) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .regular))
                    Text("Library")
                        .font(EditorialTheme.sans(size: 17, weight: .medium))
                }
                .foregroundStyle(EditorialTheme.accent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text(title)
                .font(EditorialTheme.serif(size: 17, weight: .medium))
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200)

            Spacer(minLength: 8)

            Button(action: onToggleBookmark) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isBookmarked ? EditorialTheme.accent : ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.30 : 0.08), radius: 12, x: 0, y: 6)
        // Absorb taps — the underlying page would otherwise turn on a missed
        // icon tap inside the bar.
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

// MARK: - Bottom bar

/// Editorial reader bottom bar. A floating Liquid Glass card containing
/// the chapter info row and a scrubbable progress slider with TOC tick
/// marks.
///
/// Most fields are display-only strings the caller resolves from the locator
/// and TOC. The slider is fully wired: drag updates `scrubProgress`, release
/// commits via `onScrubCommit`.
struct EditorialReaderBottomBar: View {
    let chapterTitle: String           // e.g. "30. Kaz"
    let pageLabel: String              // e.g. "p. 390"
    let timeLeftLabel: String?         // e.g. "8m left" (nil hides segment)

    let locator: Locator?
    let scrubProgress: Double?
    let tocProgressions: [Double]      // 0...1 progressions for tick marks
    /// Resolves the chapter title for an arbitrary whole-book progression
    /// so the row's title updates live during a scrub to reflect *where
    /// the slider is*, not the locator the page still shows.
    let resolveChapterTitle: (Double) -> String
    var onScrubUpdate: (Double) -> Void
    var onScrubCommit: (Double) -> Void
    var onScrubCancel: () -> Void
    var onContents: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? EditorialTheme.bg : EditorialTheme.ink }
    private var muted: Color { dark ? EditorialTheme.muted.opacity(0.85) : EditorialTheme.muted }
    private var trackOff: Color { dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18) }
    private var tickColor: Color { dark ? Color.white.opacity(0.35) : Color.black.opacity(0.30) }

    private var displayProgress: Double {
        scrubProgress ?? (locator?.locations.totalProgression ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The chevron sits as a sibling of the progress-row + slider
            // VStack — NOT nested inside the progress row — so
            // `HStack(.center)` aligns it with the true vertical center
            // of the card's main content (title/meta on top, slider on
            // bottom). Nesting it inside the progress row would pin it
            // to the top section and leave more empty card below than
            // above.
            HStack(alignment: .center, spacing: Self.chevronSpacing) {
                VStack(spacing: 0) {
                    progressRow
                    slider
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)

                chevronButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.30 : 0.08), radius: 12, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: - Rows

    /// Two-line progress row: chapter title on top, a muted meta eyebrow
    /// (time left · page · percent) below. The trailing chevron is a
    /// sibling in the parent `HStack` so it can center to the card, not
    /// the row. Both this row and the chevron tap to the same TOC sheet.
    /// During a scrub the chapter title and percent track the slider
    /// preview so the row stays in sync with the centered HUD.
    private var progressRow: some View {
        Button(action: onContents) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                Text(displayChapterTitle)
                    .font(EditorialTheme.serif(size: 20, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metaLine)
                    .editorialEyebrow(color: muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayChapterTitle), \(metaLine)")
        .accessibilityHint("Opens the table of contents")
    }

    /// Standalone trailing chevron, sibling of (progress row + slider)
    /// so its vertical center lands on the card's content center. Same
    /// action as the progress row.
    private var chevronButton: some View {
        Button(action: onContents) {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(muted)
                .frame(width: Self.chevronWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Table of contents")
    }

    fileprivate static let chevronWidth: CGFloat = 12
    fileprivate static let chevronSpacing: CGFloat = 14
    fileprivate static let rowSpacing: CGFloat = 4

    /// Single meta line under the chapter title: "8m left · p. 390 · 67%".
    /// `editorialEyebrow` uppercases and tracks it. Time-left collapses
    /// gracefully when not yet extrapolated.
    private var metaLine: String {
        var parts: [String] = []
        if let timeLeftLabel { parts.append(timeLeftLabel) }
        parts.append(pageLabel)
        parts.append("\(progressPctText)%")
        return parts.joined(separator: " · ")
    }

    private var progressPctText: String {
        String(Int((displayProgress * 100).rounded()))
    }

    /// Live chapter title: scrub preview during a drag, persisted locator
    /// title otherwise. Lets the row's chapter line mirror the centered
    /// scrub HUD without needing a second source of truth.
    private var displayChapterTitle: String {
        if let sp = scrubProgress { return resolveChapterTitle(sp) }
        return chapterTitle
    }

    // MARK: - Slider

    private var slider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackOff)
                    .frame(height: 2)

                Capsule()
                    .fill(ink)
                    .frame(width: max(0, width * CGFloat(displayProgress)), height: 2)

                ForEach(tocProgressions.indices, id: \.self) { i in
                    let p = tocProgressions[i]
                    Rectangle()
                        .fill(tickColor)
                        .frame(width: 1, height: 6)
                        .offset(x: width * CGFloat(p) - 0.5)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
                    .offset(x: width * CGFloat(displayProgress) - 9)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(scrubGesture(in: width))
        }
        .frame(height: 22)
    }

    private func scrubGesture(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onScrubUpdate(clamped(value.location.x, width: width))
            }
            .onEnded { value in
                onScrubCommit(clamped(value.location.x, width: width))
            }
    }

    private func clamped(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return max(0, min(1, Double(x / width)))
    }
}

// MARK: - HUDs (overlay state during scrub / pinch)

/// Centered HUD shown during a progress-bar scrub. Translucent rounded
/// surface showing a five-up chapter window around the scrub target —
/// two earlier chapters, the current, two later chapters — with the big
/// percentage anchored on the current row. The reader sees not just
/// which chapter they'd land in, but where it sits in the book's flow.
///
/// Chapter swaps animate as a directional slide: forward scrubs roll the
/// outgoing title up (out the top) and bring the incoming title in from
/// the bottom; backward scrubs reverse. Direction is derived from
/// successive `progress` deltas inside the HUD so the parent doesn't have
/// to thread it through. The outer neighbour pair (±2) renders smaller
/// and more faded than the inner pair (±1) so the eye is drawn down a
/// concentric distance gradient toward the current chapter.
struct ReaderScrubHUD: View {
    let progress: Double
    let previousChapter2: String?
    let previousChapter: String?
    let currentChapter: String
    let nextChapter: String?
    let nextChapter2: String?

    @State private var lastProgress: Double = -1
    @State private var direction: Direction = .forward

    private enum Direction { case forward, backward }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                neighbourLine(deduped(previousChapter2), style: .outer)
                neighbourLine(deduped(previousChapter), style: .inner)
            }

            VStack(spacing: 6) {
                Text("\(Int(progress * 100))%")
                    .font(EditorialTheme.serif(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(EditorialTheme.ink)
                currentLine
            }

            VStack(spacing: 6) {
                neighbourLine(deduped(nextChapter), style: .inner)
                neighbourLine(deduped(nextChapter2), style: .outer)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(minWidth: 240, maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onChange(of: progress) { _, new in
            // Skip the first-frame sentinel so the initial HUD render doesn't
            // pin a stale direction. Subsequent deltas set the slide axis
            // for the next chapter swap.
            if lastProgress >= 0 {
                direction = new >= lastProgress ? .forward : .backward
            }
            lastProgress = new
        }
    }

    private enum NeighbourStyle { case inner, outer }

    @ViewBuilder
    private var currentLine: some View {
        if !currentChapter.isEmpty {
            Text(currentChapter)
                .font(EditorialTheme.serif(size: 16, weight: .medium))
                .italic()
                .foregroundStyle(EditorialTheme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .id("current-\(currentChapter)")
                .transition(slideTransition)
                .animation(.snappy(duration: 0.28), value: currentChapter)
        }
    }

    /// One neighbour row in the five-up window. Outer rows (±2 from
    /// current) render smaller and more faded than inner rows (±1) so the
    /// eye reads a clear distance gradient. Missing/duplicate neighbours
    /// collapse so the HUD shrinks gracefully near book edges instead of
    /// holding empty vertical space, which would read as a layout glitch.
    @ViewBuilder
    private func neighbourLine(_ title: String?, style: NeighbourStyle) -> some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(EditorialTheme.serif(size: style == .inner ? 13 : 12))
                .italic()
                .foregroundStyle(EditorialTheme.muted.opacity(style == .inner ? 1.0 : 0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .id("\(style == .inner ? "inner" : "outer")-\(title)")
                .transition(slideTransition)
                .animation(.snappy(duration: 0.28), value: title)
        }
    }

    /// Drops a neighbour title that matches the current chapter — repeated
    /// TOC entries (which do happen — sub-chapters that share the parent's
    /// title near boundaries) would otherwise render the same string twice
    /// in adjacent rows.
    private func deduped(_ title: String?) -> String? {
        guard let title, title != currentChapter else { return nil }
        return title
    }

    /// Direction-aware slide+fade. Forward scrubs read top→bottom in
    /// physical reading order, so the *outgoing* title should exit toward
    /// the top (as if the page rolled past) and the *incoming* title
    /// should arrive from the bottom. Backward scrubs invert both edges.
    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: direction == .forward ? .bottom : .top).combined(with: .opacity),
            removal: .move(edge: direction == .forward ? .top : .bottom).combined(with: .opacity)
        )
    }

    private var accessibilityText: String {
        var parts: [String] = ["Scrubbing to \(Int(progress * 100)) percent"]
        if !currentChapter.isEmpty { parts.append(currentChapter) }
        for prev in [previousChapter, previousChapter2].compactMap({ $0 }) where prev != currentChapter {
            parts.append("after \(prev)")
        }
        for next in [nextChapter, nextChapter2].compactMap({ $0 }) where next != currentChapter {
            parts.append("before \(next)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Centered HUD shown during a left-edge brightness drag. Sun glyph + the
/// resulting screen brightness percentage. Same glass + serif treatment as
/// the font HUD so they read as siblings.
struct ReaderBrightnessHUD: View {
    let pct: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(EditorialTheme.ink)
            Text("\(pct)%")
                .font(EditorialTheme.serif(size: 32, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.ink)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
        .accessibilityLabel("Brightness \(pct) percent")
    }
}

/// Centered HUD shown during a pinch. Serif point size in a rounded glass
/// card. The input is still pct (Readium's native unit, also what
/// `FontSizeStep` and `@AppStorage` traffic in); `ReaderFontSize.pt(forPct:)`
/// converts to the displayed point value at a 16pt = 100% baseline.
struct ReaderFontHUD: View {
    let pct: Int

    private var pt: Int { ReaderFontSize.pt(forPct: pct) }

    var body: some View {
        Text("\(pt)pt")
            .font(EditorialTheme.serif(size: 32, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(EditorialTheme.ink)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(EditorialTheme.rule, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
            .accessibilityLabel("Font size \(pt) points")
    }
}
