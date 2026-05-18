import Foundation
import os
import Core
import ReadiumZIPFoundation

/// Resolves a Kobo span ID for a given progression inside a chapter.
/// Implementations may cache per-chapter parses, so the protocol is
/// `Sendable` rather than `@MainActor` — actor and non-actor conformers
/// both work, and callers `await` the resolve already.
protocol KoboSpanResolving: AnyObject, Sendable {
    func resolve(bookFileURL: URL, chapterHref: String, progression: Double) async -> String?
}

/// Actor-isolated so first-read ZIP I/O runs off the main thread. Cache
/// hits async-hop to the actor but are cheap; cache misses do real work
/// inside the nonisolated static `readSpans` (so the actor isn't held
/// during the parse).
actor KEPUBSpanResolver: KoboSpanResolving {
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

    private static func readSpans(
        bookFileURL: URL,
        chapterHref: String
    ) async -> [String]? {
        do {
            let archive = try await Archive(url: bookFileURL, accessMode: .read)
            let entries = try await archive.entries()
            guard let entry = entries.first(where: { entryMatches($0.path, chapterHref: chapterHref) }) else {
                return nil
            }
            // Bytes accumulator for the `@Sendable` ZIPFoundation Consumer
            // closure. ZIPFoundation calls the consumer serially within one
            // `extract(_:)`, so contention is zero — the lock is purely a
            // Sendable shim to allow capturing mutable state by reference.
            let bytes = OSAllocatedUnfairLock<Data>(initialState: Data())
            _ = try await archive.extract(entry) { chunk in
                bytes.withLock { $0.append(chunk) }
            }
            let data = bytes.withLock { $0 }
            guard let xhtml = String(data: data, encoding: .utf8) else { return nil }
            let spans = KoboSpanParser.spans(in: xhtml)
            return spans.isEmpty ? nil : spans
        } catch {
            return nil
        }
    }

    private static func entryMatches(_ path: String, chapterHref: String) -> Bool {
        path == chapterHref || path.hasSuffix("/" + chapterHref)
    }
}
