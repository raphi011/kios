import UIKit

/// Thin wrapper around the UIKit haptic generators so call sites read at the
/// intent level ("chapter changed") instead of leaking generator-style choices.
@MainActor
enum HapticFeedback {
    /// Subtle dampened tap fired when the reader pages from one chapter into
    /// the next via a normal swipe or edge tap. `.soft` is the most muted of
    /// the impact styles — meant to be felt, not heard.
    static func chapterChanged() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()
    }
}
