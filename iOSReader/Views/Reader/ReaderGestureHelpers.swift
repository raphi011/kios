import CoreGraphics

enum TapZone {
    case left, center, right
}

/// Classifies a tap location into a 25 % / 50 % / 25 % zone.
enum TapZoneClassifier {
    static func classify(x: CGFloat, width: CGFloat) -> TapZone {
        guard width > 0 else { return .center }
        let ratio = x / width
        if ratio < 0.25 { return .left }
        if ratio > 0.75 { return .right }
        return .center
    }
}

/// Maps a pinch scale onto a clamped, 10-step font-size percent.
enum FontSizeStep {
    static let min: Int = 60
    static let max: Int = 200
    static let step: Int = 10

    /// `startPct` is the font size at gesture begin; `scale` is the
    /// pinch recogniser's cumulative scale. Output is snapped to the
    /// nearest multiple of `step` within `[min, max]`.
    static func clamp(startPct: Int, scale: CGFloat) -> Int {
        let raw = Double(startPct) * Double(scale)
        // Add a tiny epsilon before snapping so floating-point underflow
        // (e.g. 100 × 1.15 = 114.999…) doesn't cause unexpected down-rounding.
        // .toNearestOrAwayFromZero rounds 105.0 → 110.0 deterministically
        // (.toNearestOrEven would give 100 — bad UX, "halfway never moves").
        let stepped = ((raw + 1e-9) / Double(step)).rounded(.toNearestOrAwayFromZero) * Double(step)
        let bounded = Swift.max(Double(min), Swift.min(Double(max), stepped))
        return Int(bounded)
    }
}
