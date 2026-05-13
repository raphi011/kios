import Foundation

/// Pure formatters for the Home stats strip. No `Date`, no `Locale` capture
/// at construction — each call resolves the user's current locale through
/// `NumberFormatter`.
enum StatsFormatters {
    /// "0m" for 0–59 sec or 0 min, "Nm" for <1h, "Hh Mm" for <10h, "Nh" for ≥10h.
    static func time(seconds: Int) -> String {
        let totalMinutes = seconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(totalMinutes)m" }
        if hours < 10 { return "\(hours)h \(minutes)m" }
        return "\(hours)h"
    }

    /// Plain integer, no grouping.
    static func count(_ value: Int) -> String {
        String(value)
    }

    /// Grouped integer using the user's current locale ("4,210" / "4.210").
    static func pages(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Always "N d" — fixed format independent of locale (the trailing
    /// space + literal "d" matches the design's minimal/typographic feel).
    static func streak(days: Int) -> String {
        "\(days) d"
    }
}
