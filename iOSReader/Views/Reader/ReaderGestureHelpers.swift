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
