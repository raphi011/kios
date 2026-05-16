import SwiftUI

/// Kindle-style "Back to page X" recovery affordance shown after a
/// navigation jump (scrub-commit, TOC pick, AI/search jump). Sticky
/// until the user dismisses, swipes (implicit stay), the session ends,
/// or a second nav-jump replaces it.
///
/// Driven by `ReadingStatsService.pendingJumpReturn`.
struct JumpRecoveryPill: View {
    let target: ReadingStatsService.JumpReturnTarget
    let onBack: () -> Void
    let onStay: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                Label("Back to p. \(target.fromPosition + 1)",
                      systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Button("Stay here", action: onStay)
                .buttonStyle(.borderless)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
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
    .background(Color.gray.opacity(0.2))
}
