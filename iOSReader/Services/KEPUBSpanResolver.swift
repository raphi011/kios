import Foundation
import Core
import ReadiumZIPFoundation

@MainActor
final class KEPUBSpanResolver {
    private struct Key: Hashable {
        let bookFile: URL
        let chapterHref: String
    }

    private var cache: [Key: [String]] = [:]

    func resolve(bookFileURL: URL, chapterHref: String, progression: Double) async -> String? {
        let key = Key(bookFile: bookFileURL, chapterHref: chapterHref)
        if let cached = cache[key] {
            return KoboSpanParser.span(at: progression, in: cached)
        }
        guard let spans = await Self.readSpans(
            bookFileURL: bookFileURL, chapterHref: chapterHref
        ), !spans.isEmpty else { return nil }
        cache[key] = spans
        return KoboSpanParser.span(at: progression, in: spans)
    }

    /// `nonisolated` so the ZIP read does not hop through the main actor.
    /// `Archive` itself is an actor in ReadiumZIPFoundation v3 — its work runs
    /// on its own executor.
    private nonisolated static func readSpans(
        bookFileURL: URL,
        chapterHref: String
    ) async -> [String]? {
        do {
            let archive = try await Archive(url: bookFileURL, accessMode: .read)
            let entries = try await archive.entries()
            guard let entry = entries.first(where: { $0.path.hasSuffix(chapterHref) }) else {
                return nil
            }
            var bytes = Data()
            _ = try await archive.extract(entry) { chunk in bytes.append(chunk) }
            guard let xhtml = String(data: bytes, encoding: .utf8) else { return nil }
            let spans = KoboSpanParser.spans(in: xhtml)
            return spans.isEmpty ? nil : spans
        } catch {
            return nil
        }
    }
}
