import SwiftUI

/// Editorial-styled toast banner. Sits at the top of the screen above the
/// nav bar; slides down on appear, fades on dismiss. Tap anywhere on it to
/// dismiss early. Stack icon + message; severity drives the icon color
/// (info = ink, warning = soft danger, error = danger).
struct ToastView: View {
    let toast: ToastCenter.Toast
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(symbolColor)
                .padding(.top, 1)
            Text(toast.message)
                .font(EditorialTheme.sans(size: 15, weight: .medium))
                .foregroundStyle(EditorialTheme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismiss")
    }

    private var symbolName: String {
        switch toast.level {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private var symbolColor: Color {
        switch toast.level {
        case .info: EditorialTheme.inkSoft
        case .warning: EditorialTheme.danger.opacity(0.85)
        case .error: EditorialTheme.danger
        }
    }
}

extension View {
    /// Attaches a top-aligned overlay that renders the current
    /// `ToastCenter` toast. Apply to the root scene-level view so the
    /// banner covers all non-modal content. Cross-fades when the toast
    /// changes; slides off-top when cleared.
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlayModifier(center: center))
    }
}

private struct ToastOverlayModifier: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                ToastView(toast: toast) { center.dismiss() }
                    .id(toast.id)   // forces a slide-in for each new toast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: center.current?.id)
    }
}
