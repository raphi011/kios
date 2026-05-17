import SwiftUI

// MARK: - Nav bar (large editorial title with optional eyebrow + trailing icons)

/// Editorial large-title nav bar. Matches the prototype's `KNavBar`: serif
/// title, optional mono eyebrow above, trailing icons baseline-aligned with
/// the title (Apple Books pattern, not floating above it).
/// Default serif title view used by the string-based `EditorialNavBar` init.
struct EditorialNavBarStringTitle: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(EditorialTheme.serif(size: 34, weight: .bold))
            .tracking(-0.75)
            .foregroundStyle(EditorialTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct EditorialNavBar<TitleContent: View, Trailing: View>: View {
    var eyebrow: String? = nil
    @ViewBuilder var titleContent: () -> TitleContent
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow {
                Text(eyebrow)
                    .editorialEyebrow()
                    .padding(.bottom, 8)
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                titleContent()
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

extension EditorialNavBar where TitleContent == EditorialNavBarStringTitle {
    init(title: LocalizedStringKey, eyebrow: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.eyebrow = eyebrow
        self.titleContent = { EditorialNavBarStringTitle(title: title) }
        self.trailing = trailing
    }
}

extension EditorialNavBar where TitleContent == EditorialNavBarStringTitle, Trailing == EmptyView {
    init(title: LocalizedStringKey, eyebrow: String? = nil) {
        self.init(title: title, eyebrow: eyebrow, trailing: { EmptyView() })
    }
}

/// Round 36×36 icon button used in trailing nav slots. Subtle ink-tinted
/// background, ink-colored glyph by default.
struct EditorialNavIconButton: View {
    let systemName: String
    var tint: Color = EditorialTheme.ink
    var accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.235, green: 0.196, blue: 0.157, opacity: 0.06))
                    .frame(width: 36, height: 36)
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Grouped inset list (editorial flavour)

/// Editorial grouped-inset card. Mirrors the prototype's `KList`: mono
/// eyebrow above, rounded white card, italic-serif footer below.
struct EditorialList<Content: View>: View {
    let header: LocalizedStringKey?
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    init(_ header: LocalizedStringKey? = nil,
         footer: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .editorialEyebrow()
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(EditorialTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
            .padding(.horizontal, EditorialTheme.listSidePad)

            if let footer {
                Text(footer)
                    .font(EditorialTheme.serif(size: 13))
                    .italic()
                    .foregroundStyle(EditorialTheme.muted)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            }
        }
        .padding(.top, 18)
    }
}

/// 0.5pt hairline matching the iOS list divider. Inset to match `KList`'s
/// inside-card stride (not edge-to-edge).
struct EditorialHairline: View {
    var body: some View {
        EditorialTheme.rule
            .frame(height: 0.5)
            .padding(.horizontal, EditorialTheme.rowSidePad)
    }
}

// MARK: - Segmented control

/// Editorial segmented control. Matches the prototype's `KSegmented` (rounded
/// pill track with a single elevated active chip).
struct EditorialSegmented<Selection: Hashable>: View {
    let items: [(label: LocalizedStringKey, value: Selection)]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let isActive = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(EditorialTheme.sans(size: 13, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(EditorialTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isActive ? EditorialTheme.surface : Color.clear)
                                .shadow(color: isActive
                                        ? Color.black.opacity(0.06) : .clear,
                                        radius: 2, x: 0, y: 1)
                                .shadow(color: isActive
                                        ? Color.black.opacity(0.04) : .clear,
                                        radius: 8, x: 0, y: 3)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(red: 0.235, green: 0.196, blue: 0.157, opacity: 0.06))
        )
    }
}

// MARK: - Stats card (3 cells)

/// 3-cell stats strip used on Home. Big serif numerals with mono captions
/// below; vertical hairline dividers between cells.
struct EditorialStatsCard: View {
    struct Cell {
        let number: String
        let unit: String?      // "m" for minutes, "d" for days, etc.
        let caption: LocalizedStringKey    // "Read time", "Pages", "Streak"
    }
    let cells: [Cell]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { i in
                if i > 0 {
                    EditorialTheme.rule.frame(width: 0.5, height: 48)
                }
                cellView(cells[i])
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
    }

    private func cellView(_ c: Cell) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(c.number)
                    .font(EditorialTheme.serif(size: 32, weight: .semibold))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(EditorialTheme.ink)
                if let unit = c.unit {
                    Text(unit)
                        .font(EditorialTheme.serif(size: 18, weight: .medium))
                        .foregroundStyle(EditorialTheme.muted)
                }
            }
            Text(c.caption)
                .editorialEyebrow()
        }
    }
}

// MARK: - Book row (editorial)

/// Serif title + italic author + thin ink progress bar (when 0 < p < 1),
/// or a mono meta line (when no progress or finished). Replaces the
/// project's older `BookRow` for editorial screens.
///
/// Rows are a fixed total height (`EditorialBookRow.height`) so the list
/// rhythm stays constant whether the title fits on one line or wraps to two.
/// The cover and content are vertically centered within that height; a
/// three-line title truncates with "…".
struct EditorialBookRow: View {
    /// Fixed total row height. Sized to comfortably fit a two-line 17pt serif
    /// title with the standard cover, so one-line rows render with extra
    /// vertical padding instead of being smaller.
    static let height: CGFloat = 108

    /// Cover dimensions — 2:3 portrait, vertically centered in the row.
    static let coverWidth:  CGFloat = 60
    static let coverHeight: CGFloat = 90

    let title: String
    let author: String
    /// 0…1. `0` means "not started"; show the meta line instead.
    let progress: Double
    /// "EPUB · 2.4 MB" or similar; shown when progress == 0 and finished == nil.
    let meta: String?
    /// "9 Apr" — the date the book was marked finished. Non-nil for finished
    /// rows; renders "✓ Finished {date}" in muted mono.
    let finishedLabel: String?
    /// Cover view — built by the caller (so existing thumbnail logic for
    /// kosync/Kobo/local can be reused without duplicating it here).
    @ViewBuilder var cover: () -> AnyView

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            cover()
                .frame(width: Self.coverWidth, height: Self.coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(EditorialTheme.serif(size: 17, weight: .semibold))
                    .tracking(-0.17)
                    .foregroundStyle(EditorialTheme.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                Text(author)
                    .font(EditorialTheme.serif(size: 14))
                    .italic()
                    .foregroundStyle(EditorialTheme.inkSoft)
                    .lineLimit(1)
                    .padding(.top, 3)

                trailingState
                    .padding(.top, 8)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, EditorialTheme.rowSidePad)
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailingState: some View {
        if let finishedLabel {
            Text("✓ Finished \(finishedLabel)")
                .font(EditorialTheme.mono(size: 10))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(EditorialTheme.muted)
        } else if progress > 0, progress < 1 {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(EditorialTheme.progressTrack)
                        Capsule()
                            .fill(EditorialTheme.ink)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
                .frame(maxWidth: 220)

                Text("\(Int((progress * 100).rounded()))%")
                    .font(EditorialTheme.mono(size: 10))
                    .tracking(0.2)
                    .foregroundStyle(EditorialTheme.muted)
            }
        } else if let meta {
            Text(meta)
                .font(EditorialTheme.mono(size: 10))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(EditorialTheme.muted)
        } else {
            // No progress, no meta, not finished — render an empty placeholder
            // so vertical rhythm stays consistent.
            Color.clear.frame(height: 2)
        }
    }
}

// MARK: - Settings rows

/// Editorial settings row. A content-only view — wrap it with a `Button`,
/// `NavigationLink`, or leave it as-is for non-interactive display rows.
///
/// Variants are expressed by passing/omitting fields:
/// - `value`: trailing muted-mono string (e.g. "Paper", "2 min ago")
/// - `toggle`: trailing iOS Toggle bound to the caller's state
/// - `detail`: smaller secondary line below the label
/// - `chevron`: trailing chevron — pair with a `NavigationLink` wrap
/// - `danger`: red label (e.g. Sign out)
struct EditorialRow: View {
    let label: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    var value: String? = nil
    var toggle: Binding<Bool>? = nil
    var chevron: Bool = false
    var danger: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(EditorialTheme.sans(size: 17))
                    .foregroundStyle(danger ? EditorialTheme.danger : EditorialTheme.ink)
                if let detail {
                    Text(detail)
                        .font(EditorialTheme.sans(size: 13))
                        .foregroundStyle(EditorialTheme.muted)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(EditorialTheme.mono(size: 13))
                    .foregroundStyle(EditorialTheme.muted)
                    .lineLimit(1)
            }
            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .tint(EditorialTheme.ink)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, EditorialTheme.rowSidePad)
        .padding(.vertical, 12)
        .frame(minHeight: EditorialTheme.cellMin)
        .contentShape(Rectangle())
    }
}

// MARK: - Tab bar accent helpers

/// Applies the editorial accent tint to the standard `TabView`. iOS already
/// renders the bar with a translucent material; we only override the active
/// item tint so the active tab reads as ink-red, not blue.
struct EditorialTabBarStyling: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(EditorialTheme.accent)
    }
}

extension View {
    func editorialTabBarStyling() -> some View {
        modifier(EditorialTabBarStyling())
    }
}
