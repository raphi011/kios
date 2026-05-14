import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Wraps `ReaderContainerVC` for SwiftUI. The host carries inputs (font size,
/// status-bar visibility) and outputs (locator changes, taps, pinch, dismiss).
/// EPUB only in v1; non-EPUB publications surface an error label.
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    /// Non-nil when SwiftUI wants the navigator to jump to a new locator
    /// (e.g., the user confirmed a cross-device progress prompt). The
    /// container dedupes by `Locator.jsonString`, so it's safe to keep this
    /// set across re-renders — only changes trigger navigation.
    let pendingJump: Locator?
    let fontSizePct: Int
    /// Drives whether the navigator advertises the "Ask AI" custom edit-menu
    /// action. Resolved by SwiftUI from `AIAvailability`. Read once at
    /// `makeUIViewController` time — toggling AI mid-read won't add or remove
    /// the action until the reader is reopened, matching how Readium consumes
    /// `Configuration.editingActions`.
    let canAskAI: Bool
    var onLocatorChange: @Sendable (Locator) -> Void
    var onCenterTap: () -> Void
    var onPageTurn: () -> Void
    var onPinchUpdate: (Int?) -> Void
    var onPinchCommit: (Int) -> Void
    /// Live brightness percent while the left-edge pan is active; `nil` on
    /// release so SwiftUI fades the HUD.
    var onBrightnessUpdate: (Int?) -> Void
    var onDismissRequested: () -> Void
    /// Fires with the selected text when the user picks "Ask AI" from the
    /// edit menu. SwiftUI uses this to present `AskAboutSelectionSheet`.
    var onAskAIRequested: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            let vc = ReaderContainerVC(
                publication: publication,
                initialLocator: initialLocator,
                canAskAI: canAskAI
            )
            vc.update(fontSizePct: fontSizePct)
            vc.onLocatorChange = { locator in onLocatorChange(locator) }
            vc.onCenterTap = onCenterTap
            vc.onPageTurn = onPageTurn
            vc.onPinchUpdate = onPinchUpdate
            vc.onPinchCommitToSwiftUI = onPinchCommit
            vc.onBrightnessUpdate = onBrightnessUpdate
            vc.onDismissRequested = onDismissRequested
            vc.onAskAIRequested = onAskAIRequested
            vc.applyPendingJump(pendingJump)
            return vc
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let container = uiViewController as? ReaderContainerVC else { return }
        container.update(fontSizePct: fontSizePct)
        // Re-bind callbacks each update — SwiftUI may have re-created closures.
        container.onLocatorChange = { locator in onLocatorChange(locator) }
        container.onCenterTap = onCenterTap
        container.onPageTurn = onPageTurn
        container.onPinchUpdate = onPinchUpdate
        container.onPinchCommitToSwiftUI = onPinchCommit
        container.onBrightnessUpdate = onBrightnessUpdate
        container.onDismissRequested = onDismissRequested
        container.onAskAIRequested = onAskAIRequested
        container.applyPendingJump(pendingJump)
    }

    private func errorController(_ message: String) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -24),
        ])
        return vc
    }
}
