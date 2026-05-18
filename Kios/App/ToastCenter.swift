import Foundation

/// Single-source-of-truth for transient user-facing messages. Lives on
/// `AppEnvironment.toasts`; views render the current toast via the
/// `.toastOverlay(_:)` modifier on `RootView`.
///
/// Auto-dismisses each toast after `visibleDuration`. New reports queue
/// FIFO so a burst of errors all surface (in order) instead of being
/// drowned by the first one.
@MainActor
@Observable
final class ToastCenter {

    struct Toast: Identifiable, Equatable, Sendable {
        enum Level: Sendable { case info, warning, error }
        let id: UUID
        let message: String
        let level: Level
    }

    private(set) var current: Toast?
    private var queue: [Toast] = []
    private var dismissTimer: Task<Void, Never>?

    /// How long each toast stays on screen before auto-dismissing.
    static let visibleDuration: Duration = .seconds(4)

    /// Surfaces a string message at the given severity. Coalesces to FIFO
    /// queue if a toast is already showing.
    func report(_ message: String, level: Toast.Level = .info) {
        let t = Toast(id: UUID(), message: message, level: level)
        if current == nil {
            show(t)
        } else {
            queue.append(t)
        }
    }

    /// Convenience for `Error` values — uses `.localizedDescription` and
    /// the `.error` level. Lets call sites stay one line.
    func report(_ error: Error) {
        report(error.localizedDescription, level: .error)
    }

    /// Dismiss the current toast immediately and advance to the next, if
    /// any. Bound to the tap-to-dismiss gesture on the banner.
    func dismiss() {
        dismissTimer?.cancel()
        dismissTimer = nil
        if queue.isEmpty {
            current = nil
        } else {
            show(queue.removeFirst())
        }
    }

    private func show(_ toast: Toast) {
        current = toast
        dismissTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}
