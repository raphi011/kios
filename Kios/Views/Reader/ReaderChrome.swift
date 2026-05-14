import SwiftUI
import ReadiumShared

// MARK: - Top bar

/// Editorial reader top bar. A floating Liquid Glass pill inset from the
/// screen edges, with three slots:
///
/// - leading: `‹ Library` back action (accent red)
/// - center: italic serif book title (truncates to a max width)
/// - trailing: Contents (`list.bullet`) and Type settings (`Aa`)
///
/// Contents + Type settings are stubs for now — they accept callbacks so
/// they're easy to wire up later, but pass `nil` (or a no-op) to render
/// disabled-looking buttons.
struct EditorialReaderTopBar: View {
    let title: String
    var onLibrary: () -> Void
    var onContents: () -> Void
    var onTypeSettings: () -> Void
    /// When `true`, a `sparkles` button is rendered next to Contents that
    /// opens the AI chapter-summary sheet. Gated by the caller on AI being
    /// enabled and a usable engine being available.
    var canSummarize: Bool = false
    var onSummarize: () -> Void = {}

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

            HStack(spacing: 0) {
                if canSummarize {
                    Button(action: onSummarize) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(EditorialTheme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Summarise chapter")
                }

                Button(action: onContents) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onTypeSettings) {
                    Text("Aa")
                        .font(EditorialTheme.serif(size: 18, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
    var onSummarise: () -> Void
    /// When `false`, the AI quick-action row (divider + "Summarise this
    /// chapter" button) is suppressed entirely. Gated by the caller on AI
    /// being enabled and a usable engine being available.
    var canSummarize: Bool = false
    /// Displayed in the AI quick-action row's eyebrow line — names the
    /// engine that will actually run the summary (e.g. "Built-in (Apple
    /// Intelligence)" or "Gemma 4 E4B (on-device)"). Ignored when
    /// `canSummarize` is false.
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
            if canSummarize {
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
        HStack(alignment: .lastTextBaseline, spacing: 12) {
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
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(rule)
            .frame(height: 0.5)
            .padding(.horizontal, -18)
    }

    private var aiActionRow: some View {
        Button(action: onSummarise) {
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
                    Text("Summarise this chapter")
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
/// surface stacking the target percentage over the resolved chapter heading,
/// so the reader can see *what* they're scrubbing toward.
struct ReaderScrubHUD: View {
    let progress: Double
    let chapter: String

    var body: some View {
        VStack(spacing: 6) {
            Text("\(Int(progress * 100))%")
                .font(EditorialTheme.serif(size: 32, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(EditorialTheme.ink)
            if !chapter.isEmpty {
                Text(chapter)
                    .font(EditorialTheme.serif(size: 14))
                    .italic()
                    .foregroundStyle(EditorialTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
        .accessibilityLabel("Scrubbing to \(Int(progress * 100)) percent, \(chapter)")
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

/// Centered HUD shown during a pinch. Serif percentage in a rounded glass card.
struct ReaderFontHUD: View {
    let pct: Int

    var body: some View {
        Text("\(pct)%")
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
            .accessibilityLabel("Font size \(pct) percent")
    }
}
