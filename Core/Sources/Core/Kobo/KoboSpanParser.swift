import Foundation

public enum KoboSpanParser {

    public static func spans(in xhtml: String) -> [String] {
        let nsXhtml = xhtml as NSString
        let fullRange = NSRange(location: 0, length: nsXhtml.length)

        var results: [String] = []
        var seen: Set<String> = []

        openTagRegex.enumerateMatches(in: xhtml, options: [], range: fullRange) { match, _, _ in
            guard let tagRange = match?.range else { return }
            let tag = nsXhtml.substring(with: tagRange)
            let tagNS = tag as NSString
            let tagFullRange = NSRange(location: 0, length: tagNS.length)

            guard classRegex.firstMatch(in: tag, options: [], range: tagFullRange) != nil
            else { return }

            guard let idMatch = idRegex.firstMatch(in: tag, options: [], range: tagFullRange),
                  idMatch.numberOfRanges >= 2 else { return }
            let id = tagNS.substring(with: idMatch.range(at: 1))

            guard !seen.contains(id) else { return }
            seen.insert(id)
            results.append(id)
        }

        return results
    }

    public static func span(at progression: Double, in spans: [String]) -> String? {
        guard !spans.isEmpty else { return nil }
        let raw = Int(floor(progression * Double(spans.count)))
        let index = min(spans.count - 1, max(0, raw))
        return spans[index]
    }

    private static let openTagRegex = try! NSRegularExpression(
        pattern: #"<span\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let idRegex = try! NSRegularExpression(
        pattern: #"\bid\s*=\s*"(kobo\.\d+\.\d+)""#
    )
    private static let classRegex = try! NSRegularExpression(
        pattern: #"\bclass\s*=\s*"[^"]*\bkoboSpan\b[^"]*""#
    )
}
