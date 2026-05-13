import UIKit

/// Owns the pinch-to-zoom recognizer attached to the reader container's view.
///
/// Tap and key handling have moved to Readium's `InputObservable` API via
/// `DirectionalNavigationAdapter` + `addObserver(.activate)`. Pinch stays
/// here because Readium has no pinch primitive: we use it to drive font-size
/// changes with a HUD.
///
/// WKWebView installs its own pinch recognizer. We return `true` from
/// `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` so ours fires
/// alongside it instead of being starved.
@MainActor
final class ReaderInputHandlers: NSObject {
    /// Pinch began or changed — payload is the target percent for the HUD
    /// (or `nil` to dismiss the HUD when the gesture cancelled).
    var onPinchUpdate: ((Int?) -> Void)?
    /// Pinch ended successfully — payload is the percent to commit.
    var onPinchCommit: ((Int) -> Void)?

    /// The font-size percent that was in effect when the pinch began.
    /// Captured at `.began` so subsequent `.changed` events scale from
    /// the same anchor even as we update the HUD.
    private var pinchStartPct: Int = 100

    /// Closure that returns the currently-committed percent. Kept as a
    /// closure (not a value) so it always reflects the latest `@AppStorage`
    /// without us having to re-set a property on every change.
    private let currentFontSizePct: () -> Int

    init(currentFontSizePct: @escaping () -> Int) {
        self.currentFontSizePct = currentFontSizePct
        super.init()
    }

    func attach(to view: UIView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            pinchStartPct = currentFontSizePct()
            onPinchUpdate?(pinchStartPct)
        case .changed:
            let target = FontSizeStep.clamp(startPct: pinchStartPct, scale: gr.scale)
            onPinchUpdate?(target)
        case .ended:
            let target = FontSizeStep.clamp(startPct: pinchStartPct, scale: gr.scale)
            onPinchCommit?(target)
        case .cancelled, .failed:
            onPinchUpdate?(nil)
        default:
            break
        }
    }
}

extension ReaderInputHandlers: UIGestureRecognizerDelegate {
    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
