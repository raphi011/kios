import Foundation

/// Pure-Swift extraction of `koboSpan` ids from KEPUB-style XHTML.
///
/// KEPUBs (produced by `kepubify`) wrap text runs in
/// `<span class="koboSpan" id="kobo.<element>.<run>">…</span>`. Real Kobo
/// devices use these ids as within-chapter anchors. This parser scans the
/// chapter XHTML, returning the ids in document order so iOS can pick the
/// span that best matches a Readium `progression` value before pushing a
/// bookmark.
public enum KoboSpanParser {

    /// Returns all koboSpan ids in document order. Matches `<span>` opening
    /// tags whose attributes include both `class="koboSpan"` and
    /// `id="kobo.<digits>.<digits>"` (attribute order is irrelevant).
    /// Duplicates keep first occurrence. Empty if none found.
    public static func spans(in xhtml: String) -> [String] {
        // Pattern matches `<span` followed by any attributes (no `>`), up to
        // the closing `>` of the opening tag. Self-closing `<span ... />` is
        // unusual for koboSpan (kepubify always emits an explicit closer) but
        // still captured — we only care about attributes on the open tag.
        let openTagPattern = #"<span\b[^>]*>"#
        guard let openTagRegex = try? NSRegularExpression(
            pattern: openTagPattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let idPattern = #"\bid\s*=\s*"(kobo\.\d+\.\d+)""#
        let classPattern = #"\bclass\s*=\s*"[^"]*\bkoboSpan\b[^"]*""#
        guard let idRegex = try? NSRegularExpression(pattern: idPattern),
              let classRegex = try? NSRegularExpression(pattern: classPattern) else {
            return []
        }

        let nsXhtml = xhtml as NSString
        let fullRange = NSRange(location: 0, length: nsXhtml.length)

        var results: [String] = []
        var seen: Set<String> = []

        openTagRegex.enumerateMatches(in: xhtml, options: [], range: fullRange) { match, _, _ in
            guard let tagRange = match?.range else { return }
            let tag = nsXhtml.substring(with: tagRange)
            let tagNS = tag as NSString
            let tagFullRange = NSRange(location: 0, length: tagNS.length)

            // Require class="koboSpan" (allow whitespace variants and
            // additional class tokens, although kepubify emits only the one).
            guard classRegex.firstMatch(in: tag, options: [], range: tagFullRange) != nil
            else { return }

            // Extract id="kobo.X.Y".
            guard let idMatch = idRegex.firstMatch(in: tag, options: [], range: tagFullRange),
                  idMatch.numberOfRanges >= 2 else { return }
            let id = tagNS.substring(with: idMatch.range(at: 1))

            guard !seen.contains(id) else { return }
            seen.insert(id)
            results.append(id)
        }

        return results
    }

    /// Picks the span at `floor(progression * spans.count)`, clamped to the
    /// valid range. Returns nil if `spans` is empty.
    ///
    /// Examples (with 10 spans):
    /// - progression `0.0` → index 0 (first)
    /// - progression `0.5` → index 5 (sixth)
    /// - progression `1.0` → index 9 (last; clamped from 10)
    public static func span(at progression: Double, in spans: [String]) -> String? {
        guard !spans.isEmpty else { return nil }
        let raw = Int(floor(progression * Double(spans.count)))
        let index = min(spans.count - 1, max(0, raw))
        return spans[index]
    }
}
