import SwiftUI
import ReadiumShared

/// Top bar shown when chrome is visible. Close button on the left,
/// truncated title in the middle, nothing on the right.
struct ReaderTopBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Right-side spacer keeps the title visually centered against the
            // close button's 44pt hit target.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.regularMaterial)
        // Absorb taps anywhere in the bar so they don't reach the page
        // beneath (otherwise a tap on empty title area would turn the page).
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Bottom strip with progress bar and `34% • Chapter 4` label. Scrubbable:
/// dragging the bar previews a target progression (caller renders a HUD via
/// `onScrubUpdate`) and commits the jump on release via `onScrubCommit`.
struct ReaderBottomProgressBar: View {
    let locator: Locator?
    /// Non-nil while the user is dragging — display reflects the scrub
    /// position, not the navigator's actual locator. Reset to nil after commit.
    let scrubProgress: Double?
    /// Resolves the TOC heading for a given whole-book progression.
    let chapterTitle: (Double) -> String
    var onScrubUpdate: (Double) -> Void
    var onScrubCommit: (Double) -> Void
    var onScrubCancel: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * CGFloat(displayProgress)))
                }
                .frame(height: 4)
                .contentShape(Rectangle())
                .gesture(scrubGesture(in: geo.size.width))
            }
            // Tall hit area for the drag — the visible capsule is only 4pt,
            // but the gesture treats the whole 28pt strip as draggable so a
            // moving fingertip isn't lost between samples.
            .frame(height: 28)
            HStack {
                Text("\(Int(displayProgress * 100))%")
                    .font(.caption.monospacedDigit())
                Text("•")
                    .font(.caption)
                Text(displayChapterLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .contentShape(Rectangle())
    }

    private var displayProgress: Double {
        scrubProgress ?? (locator?.locations.totalProgression ?? 0)
    }

    private var displayChapterLabel: String {
        if let sp = scrubProgress {
            return chapterTitle(sp)
        }
        if let title = locator?.title, !title.isEmpty {
            return title
        }
        return chapterTitle(displayProgress)
    }

    private func scrubGesture(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onScrubUpdate(clampedProgress(value.location.x, in: width))
            }
            .onEnded { value in
                onScrubCommit(clampedProgress(value.location.x, in: width))
            }
    }

    private func clampedProgress(_ x: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return max(0, min(1, Double(x / width)))
    }
}

/// Centered HUD shown during a progress-bar scrub. Mirrors `ReaderFontHUD`'s
/// translucent rounded surface but stacks percent over the resolved chapter
/// heading so the reader can see *what* they're scrubbing toward.
struct ReaderScrubHUD: View {
    let progress: Double
    let chapter: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(progress * 100))%")
                .font(.title2.weight(.semibold).monospacedDigit())
            if !chapter.isEmpty {
                Text(chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Scrubbing to \(Int(progress * 100)) percent, \(chapter)")
    }
}

/// Centered HUD shown during a pinch. "120%" inside a rounded background.
struct ReaderFontHUD: View {
    let pct: Int

    var body: some View {
        Text("\(pct)%")
            .font(.title2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Font size \(pct) percent")
    }
}
