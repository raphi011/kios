import SwiftUI
import ReadiumShared

// MARK: - Top bar

/// Editorial reader top bar. A floating Liquid Glass pill inset from the
/// screen edges, with three slots:
///
/// - leading: `‹ Library` back action (accent red)
/// - center: italic serif book title (truncates to a max width)
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
                .font(EditorialTheme.serif(size: 14, weight: .medium))
                .italic()
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160)

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

/// Editorial reader bottom bar. A floating Liquid Glass card containing the
/// chapter info row, a scrubbable progress slider with TOC tick marks, and a
/// trailing AI quick-action row separated by a hairline.
///
/// Most fields are display-only strings the caller resolves from the locator
/// and TOC. The slider is fully wired: drag updates `scrubProgress`, release
/// commits via `onScrubCommit`.
struct EditorialReaderBottomBar: View {
    let chapterEyebrow: String         // e.g. "CHAPTER IV"
    let chapterTitle: String           // e.g. "The Platonic Fold"
    let pageLabel: String              // e.g. "p. 142 / 316"
    let timeLeftLabel: String?         // e.g. "3h 12m left" (nil hides line)

    let locator: Locator?
    let scrubProgress: Double?
    let tocProgressions: [Double]      // 0...1 progressions for tick marks
    let resolveChapterTitle: (Double) -> String
    var onScrubUpdate: (Double) -> Void
    var onScrubCommit: (Double) -> Void
    var onScrubCancel: () -> Void
    var onContents: () -> Void
    var onInsights: () -> Void
    /// When `false`, the AI quick-action row (divider + "Insights" button)
    /// is suppressed entirely. Gated by the caller on AI being enabled and
    /// a usable engine being available.
    var canShowInsights: Bool = false
    /// Displayed in the AI quick-action row's eyebrow line — names the
    /// engine that will run the analysis (e.g. "Built-in (Apple
    /// Intelligence)" or "Gemma 4 E4B (on-device)"). Ignored when
    /// `canShowInsights` is false.
    var engineLabel: String = "On-device"

    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? EditorialTheme.bg : EditorialTheme.ink }
    private var muted: Color { dark ? EditorialTheme.muted.opacity(0.85) : EditorialTheme.muted }
    private var rule: Color { dark ? Color.white.opacity(0.10) : EditorialTheme.rule }
    private var trackOff: Color { dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18) }
    private var tickColor: Color { dark ? Color.white.opacity(0.35) : Color.black.opacity(0.30) }

    private var displayProgress: Double {
        scrubProgress ?? (locator?.locations.totalProgression ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            chapterRow
            slider
                .padding(.top, 12)
            if canShowInsights {
                divider
                    .padding(.vertical, 12)
                aiActionRow
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

    private var chapterRow: some View {
        Button(action: onContents) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapterEyebrow)
                        .editorialEyebrow(color: muted)
                    Text(displayChapterTitle)
                        .font(EditorialTheme.serif(size: 16, weight: .medium))
                        .italic()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(pageLabel)
                        .editorialEyebrow(color: muted)
                    if let timeLeftLabel {
                        Text(timeLeftLabel)
                            .font(EditorialTheme.serif(size: 13))
                            .italic()
                            .foregroundStyle(muted)
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(muted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chapter \(chapterEyebrow), \(displayChapterTitle)")
        .accessibilityHint("Opens the table of contents")
    }

    private var divider: some View {
        Rectangle()
            .fill(rule)
            .frame(height: 0.5)
            .padding(.horizontal, -18)
    }

    private var aiActionRow: some View {
        Button(action: onInsights) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(EditorialTheme.accentSoft)
                        .frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(EditorialTheme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Insights")
                        .font(EditorialTheme.sans(size: 15, weight: .medium))
                        .foregroundStyle(ink)
                    Text(engineLabel)
                        .editorialEyebrow(color: muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(muted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var displayChapterTitle: String {
        if let sp = scrubProgress { return resolveChapterTitle(sp) }
        return chapterTitle
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
