import Foundation
import ReadiumShared

/// Pulls a chapter's plain-text body from a Readium `Publication`.
///
/// The extractor opens the chapter resource, strips HTML tags + entities,
/// normalizes whitespace, and optionally slices the text to a progression
/// cutoff. The cut is aligned to the nearest paragraph or sentence boundary
/// so summaries never end mid-word.
struct ChapterTextExtractor {
    let publication: Publication

    /// Returns the chapter's plain text.
    ///
    /// - Parameters:
    ///   - link: A reading-order `Link` (e.g. `publication.readingOrder[i]`).
    ///   - cutoff: Optional progression in `(0, 1)`. When set, the result is
    ///     truncated to roughly `cutoff * length` characters and aligned to a
    ///     paragraph (preferred), sentence, or line boundary. `nil`, `<=0`,
    ///     and `>=1` all return the full plain text.
    /// - Throws: `ExtractError.resourceUnavailable` if Readium cannot resolve
    ///   the link, or the underlying `ReadError` if the resource cannot be
    ///   read / decoded.
    func extract(link: Link, cutoff: Double? = nil) async throws -> String {
        guard let resource = publication.get(link) else {
            throw ExtractError.resourceUnavailable
        }
        let html = try await resource.read().asString().get()
        let plain = Self.htmlToPlain(html)

        guard let cutoff, cutoff > 0, cutoff < 1 else { return plain }
        let target = Int(Double(plain.count) * cutoff)
        return alignToParagraph(plain, target: target)
    }

    /// Truncates `text` at-or-before `target` characters, biased to a
    /// paragraph break (`"\n\n"`), then a sentence end (`". "`), then a
    /// single newline. Falls back to a hard cut at `target`.
    private func alignToParagraph(_ text: String, target: Int) -> String {
        guard target > 0, target < text.count else { return text }
        let upper = text.index(text.startIndex, offsetBy: target)
        let head = text[..<upper]
        if let lastDouble = head.range(of: "\n\n", options: .backwards) {
            return String(text[..<lastDouble.upperBound])
        }
        if let lastDot = head.range(of: ". ", options: .backwards) {
            // Keep the period, drop the trailing space.
            let endIncludingPeriod = text.index(after: lastDot.lowerBound)
            return String(text[..<endIncludingPeriod])
        }
        if let lastLF = head.range(of: "\n", options: .backwards) {
            return String(text[..<lastLF.upperBound])
        }
        return String(head)
    }

    /// Converts a fragment of XHTML/HTML into plain text suitable for an LLM
    /// prompt. Order matters: tag-blocks (`<script>`, `<style>`) are removed
    /// before the generic tag regex, so their contents are dropped along
    /// with the tags themselves.
    static func htmlToPlain(_ html: String) -> String {
        var s = html
        s = stripTagBlock(s, tag: "script")
        s = stripTagBlock(s, tag: "style")
        s = s.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"</p\s*>"#,
            with: "\n\n",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&nbsp;": " ",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…",
        ]
        for (key, value) in entities {
            s = s.replacingOccurrences(of: key, with: value)
        }
        // Collapse runs of inline whitespace, but preserve paragraph breaks.
        s = s.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTagBlock(_ s: String, tag: String) -> String {
        s.replacingOccurrences(
            of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
            with: "",
            options: .regularExpression
        )
    }

    enum ExtractError: Error {
        /// The publication had no resource for the requested link.
        case resourceUnavailable
    }
}
