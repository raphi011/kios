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
        let location: KoboLocation? = {
            guard let id = koboSpanId, !id.isEmpty else { return nil }
            return KoboLocation(value: id, type: "KoboSpan", source: href)
        }()
        return .init(
            progressPercent: progression * 100,
            contentSourceProgressPercent: totalProgression * 100,
            location: location
        )
    }

    /// koboSpan IDs only contain `[a-zA-Z0-9.]`, so escaping `.` suffices.
    private static func escapeCSS(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: #"\."#)
    }
}
