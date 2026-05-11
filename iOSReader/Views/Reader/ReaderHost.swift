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
    let fontSizePct: Int
    let statusBarHidden: Bool
    var onLocatorChange: @Sendable (Locator) -> Void
    var onCenterTap: () -> Void
    var onPinchUpdate: (Int?) -> Void
    var onPinchCommit: (Int) -> Void
    var onDismissRequested: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            let vc = ReaderContainerVC(publication: publication, initialLocator: initialLocator)
            vc.update(fontSizePct: fontSizePct, statusBarHidden: statusBarHidden)
            vc.onLocatorChange = { locator in onLocatorChange(locator) }
            vc.onCenterTap = onCenterTap
            vc.onPinchUpdate = onPinchUpdate
            vc.onPinchCommitToSwiftUI = onPinchCommit
            vc.onDismissRequested = onDismissRequested
            return vc
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let container = uiViewController as? ReaderContainerVC else { return }
        container.update(fontSizePct: fontSizePct, statusBarHidden: statusBarHidden)
        // Re-bind callbacks each update — SwiftUI may have re-created closures.
        container.onLocatorChange = { locator in onLocatorChange(locator) }
        container.onCenterTap = onCenterTap
        container.onPinchUpdate = onPinchUpdate
        container.onPinchCommitToSwiftUI = onPinchCommit
        container.onDismissRequested = onDismissRequested
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
