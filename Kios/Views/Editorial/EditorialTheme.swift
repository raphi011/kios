import SwiftUI

/// Editorial design tokens. Source of truth lives in the design package
/// (`kios-tokens.jsx`); keep both in sync.
///
/// Newsreader/Geist aren't bundled yet, so the serif/sans stacks map to
/// Apple's system designs (`.serif` = New York, default = SF Pro / SF Text).
/// When the project ships custom fonts, swap the `Font` factories below —
/// nothing else needs to change.
enum EditorialTheme {
    // MARK: - Surfaces
    static let bg = Color(
        light: Color(red: 0.980, green: 0.972, blue: 0.957),  // FAF8F4
        dark:  Color(red: 0.102, green: 0.090, blue: 0.078)   // 1A1714
    )
    static let surface = Color(
        light: .white,                                          // FFFFFF
        dark:  Color(red: 0.141, green: 0.122, blue: 0.106)    // 241F1B
    )
    static let surfaceAlt = Color(
        light: Color(red: 0.949, green: 0.937, blue: 0.910),  // F2EFE8
        dark:  Color(red: 0.176, green: 0.153, blue: 0.137)   // 2D2723
    )

    // MARK: - Ink
    static let ink = Color(
        light: Color(red: 0.102, green: 0.090, blue: 0.078),  // 1A1714
        dark:  Color(red: 0.980, green: 0.972, blue: 0.957)   // FAF8F4
    )
    static let inkSoft = Color(
        light: Color(red: 0.239, green: 0.212, blue: 0.176),  // 3D362D
        dark:  Color(red: 0.851, green: 0.823, blue: 0.773)   // D9D2C5
    )
    static let muted = Color(
        light: Color(red: 0.478, green: 0.443, blue: 0.396),  // 7A7165
        dark:  Color(red: 0.612, green: 0.572, blue: 0.525)   // 9C9286
    )

    // MARK: - Lines
    static let rule = Color(
        light: Color(red: 0.235, green: 0.196, blue: 0.157, opacity: 0.10),
        dark:  Color(red: 0.980, green: 0.972, blue: 0.957, opacity: 0.12)
    )
    static let ruleStrong = Color(
        light: Color(red: 0.102, green: 0.090, blue: 0.078),  // 1A1714
        dark:  Color(red: 0.980, green: 0.972, blue: 0.957)   // FAF8F4
    )

    // MARK: - Accent (ink red, used sparingly)
    // Lifted in dark (B53F32 → D85A4A) because saturated reds appear muddy
    // on dark backgrounds — the perceived hue should match across themes.
    static let accent = Color(
        light: Color(red: 0.710, green: 0.247, blue: 0.196),  // B53F32
        dark:  Color(red: 0.847, green: 0.353, blue: 0.290)   // D85A4A
    )
    static let accentSoft = Color(
        light: Color(red: 0.949, green: 0.882, blue: 0.867),  // F2E1DD
        dark:  Color(red: 0.227, green: 0.122, blue: 0.106)   // 3A1F1B
    )

    // MARK: - Status
    static let ok = Color(
        light: Color(red: 0.180, green: 0.490, blue: 0.357),  // 2E7D5B
        dark:  Color(red: 0.357, green: 0.753, blue: 0.541)   // 5BC08A
    )
    static let danger = Color(
        light: Color(red: 0.769, green: 0.180, blue: 0.122),  // C42E1F
        dark:  Color(red: 0.902, green: 0.420, blue: 0.373)   // E66B5F
    )

    // MARK: - Track shades (for progress bars in either theme)
    static let progressTrack = Color(
        light: Color(red: 0.235, green: 0.196, blue: 0.157, opacity: 0.12),
        dark:  Color(red: 0.980, green: 0.972, blue: 0.957, opacity: 0.14)
    )

    // MARK: - Geometry
    static let cardRadius:  CGFloat = 14    // grouped-list inset card
    static let cellMin:     CGFloat = 44    // min touch target (iOS HIG)
    static let listSidePad: CGFloat = 16    // outer card margin
    static let rowSidePad:  CGFloat = 16    // inside-card row padding

    // MARK: - Type
    /// Newsreader stand-in: Apple's New York via the serif system design.
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func serifItalic(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // SwiftUI applies `.italic()` at the modifier level — the helper just
        // returns the serif face; callers add `.italic()` on the Text.
        .system(size: size, weight: weight, design: .serif)
    }

    /// Geist stand-in: SF Pro Text / system default.
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Geist Mono stand-in: SF Mono via the monospaced system design.
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Convenience for the editorial monospace "eyebrow" style used above section
/// headers, on stat captions, and on meta lines — tracked uppercase mono.
struct EditorialEyebrow: ViewModifier {
    var color: Color = EditorialTheme.muted

    func body(content: Content) -> some View {
        content
            .font(EditorialTheme.mono(size: 11, weight: .medium))
            .tracking(1.4)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension View {
    /// Tracked uppercase mono — section eyebrows, stat captions, meta.
    func editorialEyebrow(color: Color = EditorialTheme.muted) -> some View {
        modifier(EditorialEyebrow(color: color))
    }
}
