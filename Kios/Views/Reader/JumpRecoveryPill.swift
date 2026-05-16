import SwiftUI

/// Kindle-style "Back to page X" recovery affordance shown after a
/// navigation jump (scrub-commit, TOC pick, AI/search jump). Sticky
/// until the user dismisses (Stay/Back), the session ends, or a second
/// nav-jump replaces it.
///
/// Driven by `ReadingStatsService.pendingJumpReturn`.
struct JumpRecoveryPill: View {
    let target: ReadingStatsService.JumpReturnTarget
    let onBack: () -> Void
    let onStay: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back to p. \(target.fromPosition + 1)")
                        .font(EditorialTheme.sans(size: 14, weight: .medium))
                }
                .foregroundStyle(EditorialTheme.accent)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(EditorialTheme.rule)
                .frame(width: 1, height: 16)

            Button(action: onStay) {
                Text("Stay here")
                    .font(EditorialTheme.sans(size: 14, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(EditorialTheme.surface)
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
                .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
        )
        .overlay(
            Capsule().stroke(EditorialTheme.rule, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You jumped to page \(target.toPosition + 1). Back to page \(target.fromPosition + 1) or stay here.")
    }
}

#Preview {
    JumpRecoveryPill(
        target: .init(fromPosition: 41, toPosition: 200),
        onBack: {},
        onStay: {}
    )
    .padding()
    .background(EditorialTheme.bg)
}
