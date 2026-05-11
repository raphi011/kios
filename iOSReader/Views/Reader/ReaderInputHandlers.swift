import UIKit

/// Owns the tap + pinch recognizers attached to a host view (the reader
/// container's view). Calls back to the container with classified events.
///
/// Recognizers attach to the *container's* view, not a transparent overlay
/// subview, because Readium's WebView is a descendant of the container's
/// view — a recognizer on the parent sees touches from all descendants
/// without needing a subview that would interfere with hit-testing.
///
/// The tap recognizer has `cancelsTouchesInView = true` so Readium's
/// built-in tap-to-turn behaviour is suppressed; otherwise both would fire.
/// Long-press (text selection) is a separate recognizer in Readium's
/// WebViews and is unaffected.
@MainActor
final class ReaderInputHandlers: NSObject {
    /// Called for taps in the left 25 %.
    var onLeftTap: (() -> Void)?
    /// Called for taps in the center 50 %.
    var onCenterTap: (() -> Void)?
    /// Called for taps in the right 25 %.
    var onRightTap: (() -> Void)?
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
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        // Absorbs the touch so Readium's WebView never sees it as a tap —
        // suppresses Readium's built-in tap-to-turn-page behaviour.
        tap.cancelsTouchesInView = true
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard let host = gr.view else { return }
        let x = gr.location(in: host).x
        switch TapZoneClassifier.classify(x: x, width: host.bounds.width) {
        case .left:   onLeftTap?()
        case .center: onCenterTap?()
        case .right:  onRightTap?()
        }
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
