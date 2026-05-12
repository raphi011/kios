import Foundation

public enum KoboProgressMapper {

    public static func toLocator(
        source: String,
        type: String,
        value: String,
        progressPercent: Double,
        totalPercent: Double
    ) -> String {
        var locations: [String: Any] = [
            "progression": progressPercent / 100.0,
            "totalProgression": totalPercent / 100.0,
        ]
        if value.hasPrefix("kobo.") {
            locations["cssSelector"] = "#" + escapeCSS(value)
        }
        let locator: [String: Any] = [
            "href": source,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        let data = try! JSONSerialization.data(withJSONObject: locator)
        return String(data: data, encoding: .utf8)!
    }

    public static func toKoboBookmark(
        href: String,
        koboSpanId: String?,
        progression: Double,
        totalProgression: Double
    ) -> KoboStateUpdate.State.Bookmark {
        // CWA's Kobo blueprint rejects bookmarks without a Location (Flask 400
        // before the route handler). When we don't have a real koboSpan id —
        // Readium emits locators without `cssSelector` for normal page-turns
        // and scrubs — fall back to a deterministic placeholder. The
        // percentages still carry the precise progress; a real Kobo device
        // reading this back will land in the right chapter and the local
        // re-open path on iOS falls back to `progression` when the selector
        // doesn't resolve to a real element.
        let id = koboSpanId.flatMap { $0.isEmpty ? nil : $0 } ?? "kobo.0.0"
        let location = KoboLocation(value: id, type: "KoboSpan", source: href)
        return .init(
            progressPercent: progression * 100,
            contentSourceProgressPercent: totalProgression * 100,
            location: location
        )
    }

    /// koboSpan IDs only contain `[a-zA-Z0-9.]`, so escaping `.` suffices.
    /// Paired with `unescapeCSS` so `KoboBackend` can extract the original id
    /// back out of the canonical locator JSON. **Edit these two in lockstep.**
    static func escapeCSS(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: #"\."#)
    }

    /// Inverse of `escapeCSS`. Internal so `KoboBackend.buildBookmark` can
    /// undo the escape when round-tripping a koboSpan id through the
    /// Readium-shape locator.
    static func unescapeCSS(_ s: String) -> String {
        s.replacingOccurrences(of: #"\."#, with: ".")
    }
}
