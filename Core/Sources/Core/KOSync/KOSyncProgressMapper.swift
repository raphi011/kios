import Foundation

/// kosync-specific progress mapper. Translates between our internal progress
/// representation and the kosync `progress` string. We use
/// `"<chapter-index>:<intra-progression>"` (e.g. `"5:0.4231"`). KOReader uses
/// xpointers like `/body/DocFragment[N]/body/p[12]/text().42`; we extract the
/// DocFragment index for chapter-level seeking and accept the loss of
/// intra-chapter precision (callers rely on `percentage` for the global
/// location).
///
/// A parallel `KoboProgressMapper` handles the Kobo wire format.
///
/// See `docs/research.md` §2.1 for the wire-format context.
public enum KOSyncProgressMapper {

    public enum Error: Swift.Error, Equatable, Sendable {
        case unparsable(String)
    }

    /// Encodes our `(chapter, intraProgression)` representation as a kosync
    /// `progress` string. `intraProgression` is clamped silently into [0, 1]
    /// — out-of-range values would be a programmer error.
    public static func encodeProgress(chapter: Int, intraProgression: Double) -> String {
        let clamped = min(max(intraProgression, 0), 1)
        return "\(chapter):\(format(clamped))"
    }

    /// Decodes a kosync `progress` string. Recognises:
    /// - our format `"<chapter>:<progression>"`
    /// - KOReader xpointers containing `DocFragment[N]` (intra-chapter
    ///   position is lost, returned as 0).
    public static func decodeProgress(_ s: String) throws -> (chapter: Int, intraProgression: Double) {
        if let parsed = parseOurFormat(s) { return parsed }
        if let chapter = parseKOReaderDocFragment(s) { return (chapter, 0) }
        throw Error.unparsable(s)
    }

    // MARK: - private

    private static func parseOurFormat(_ s: String) -> (Int, Double)? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let chapter = Int(parts[0]),
              let progression = Double(parts[1]),
              progression >= 0, progression <= 1
        else { return nil }
        return (chapter, progression)
    }

    /// Extracts an integer from `/body/DocFragment[N]/...`. Returns N-1 (we
    /// store chapters 0-indexed; KOReader xpointer is 1-indexed).
    private static func parseKOReaderDocFragment(_ s: String) -> Int? {
        guard let bracketRange = s.range(of: #"DocFragment\[(\d+)\]"#, options: .regularExpression),
              let digitRange = s[bracketRange].range(of: #"\d+"#, options: .regularExpression),
              let n = Int(s[bracketRange][digitRange])
        else { return nil }
        return max(0, n - 1)
    }

    /// Locale-independent 4-decimal formatting.
    private static func format(_ d: Double) -> String {
        String(format: "%.4f", d)
    }
}
