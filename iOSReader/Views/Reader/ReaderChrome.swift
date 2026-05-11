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
                .truncationMode(.middle)
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

/// Bottom strip with progress bar and `34% • Chapter 4` label.
struct ReaderBottomProgressBar: View {
    let locator: Locator?

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                Text("•")
                    .font(.caption)
                Text(chapterLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        // Absorb taps so the page beneath doesn't see them.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var progress: Double {
        locator?.locations.totalProgression ?? 0
    }

    private var chapterLabel: String {
        // `Locator.title` is the chapter heading where Readium can resolve it.
        if let title = locator?.title, !title.isEmpty {
            return title
        }
        return "Chapter ?"
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
