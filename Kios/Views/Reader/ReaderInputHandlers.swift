import UIKit

/// Owns the UIKit gesture recognizers attached to the reader container's view.
///
/// Tap and key handling have moved to Readium's `InputObservable` API via
/// `DirectionalNavigationAdapter` + `addObserver(.activate)`. The recognizers
/// here are for things Readium doesn't expose: **pinch** for font-size
/// changes, and a **left-edge vertical pan** for screen brightness.
///
/// Both recognizers:
/// - set `cancelsTouchesInView = false`, so a tap that never satisfies the
///   recognizer's threshold still reaches WKWebView / Readium's tap observer
///   (which is how left/right edge taps still turn pages while this view sits
///   in the same hit-test tree)
/// - return `true` from `shouldRecognizeSimultaneouslyWith` so they fire
///   alongside WKWebView's own recognizers instead of being starved
@MainActor
final class ReaderInputHandlers: NSObject {

    // MARK: - Pinch (font size)

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

    // MARK: - Brightness (left-edge vertical pan)

    /// Width of the active brightness zone on the left edge, as a fraction
    /// of the host view's width.
    static let brightnessZoneFraction: CGFloat = 0.22

    /// Drag distance (in host-view heights) that maps to a full 0→1
    /// brightness range. Smaller = finer control.
    private static let brightnessDragRange: CGFloat = 0.6

    /// Brightness HUD update — payload is the live brightness percent, or
    /// `nil` once the gesture ends so the HUD can dismiss.
    var onBrightnessUpdate: ((Int?) -> Void)?

    /// `UIScreen.main.brightness` at the moment the brightness pan began.
    /// nil between gestures.
    private var brightnessStart: CGFloat?

    /// Host view, captured in `attach(to:)` so the recognizer can resolve
    /// its bounds for zone math.
    private weak var hostView: UIView?

    /// Brightness pan recognizer — kept so the delegate methods can identify
    /// it (vs pinch) without `as?` checks.
    private weak var brightnessPan: UIPanGestureRecognizer?

    init(currentFontSizePct: @escaping () -> Int) {
        self.currentFontSizePct = currentFontSizePct
        super.init()
    }

    func attach(to view: UIView) {
        hostView = view

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleBrightnessPan(_:)))
        pan.cancelsTouchesInView = false
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        brightnessPan = pan
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

    @objc private func handleBrightnessPan(_ gr: UIPanGestureRecognizer) {
        guard let view = hostView else { return }

        switch gr.state {
        case .began:
            brightnessStart = UIScreen.main.brightness
            let pct = Int((brightnessStart! * 100).rounded())
            onBrightnessUpdate?(pct)
        case .changed:
            guard let start = brightnessStart else { return }
            let translation = gr.translation(in: view)
            let viewHeight = max(view.bounds.height, 1)
            // Up = brighter, so negate the (positive-going-down) Y delta.
            let normalized = -translation.y / (viewHeight * Self.brightnessDragRange)
            let target = max(0, min(1, start + normalized))
            UIScreen.main.brightness = target
            onBrightnessUpdate?(Int((target * 100).rounded()))
        case .ended, .cancelled, .failed:
            brightnessStart = nil
            onBrightnessUpdate?(nil)
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

    /// Called when a recognizer wants to transition from `.possible` to
    /// `.began`. For the brightness pan, this is where we filter out drags
    /// that didn't start on the left edge or that are dominantly horizontal —
    /// returning `false` flips the recognizer's state to `.failed` instead,
    /// leaving the touch available for WebKit / Readium / SwiftUI to handle.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              pan === brightnessPan,
              let view = hostView else {
            return true
        }
        let location = pan.location(in: view)
        let zoneWidth = view.bounds.width * Self.brightnessZoneFraction
        guard location.x < zoneWidth else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }
}
