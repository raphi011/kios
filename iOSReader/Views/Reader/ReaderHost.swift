import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Wraps a Readium navigator in a UIViewControllerRepresentable.
/// Supports EPUB only in v1 (PDF/CBZ require an HTTPServer adapter not included
/// in the current dependency set).
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    var onLocatorChange: @Sendable (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onLocatorChange)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            do {
                let nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocator
                )
                nav.delegate = context.coordinator
                return nav
            } catch {
                return errorController("Failed to open EPUB: \(error.localizedDescription)")
            }
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, EPUBNavigatorDelegate, @unchecked Sendable {
        let onChange: @Sendable (Locator) -> Void

        init(onChange: @escaping @Sendable (Locator) -> Void) {
            self.onChange = onChange
        }

        nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onChange(locator)
        }

        nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
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
