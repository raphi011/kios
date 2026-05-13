import Testing
import Foundation
import ReadiumZIPFoundation
@testable import Kios

@Suite("KEPUBSpanResolver", .serialized)
@MainActor
struct KEPUBSpanResolverTests {

    @Test func resolvesFirstSpanAtZeroProgression() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let id = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/chapter1.xhtml",
            progression: 0.0
        )
        #expect(id == "kobo.1.1")
    }

    @Test func resolvesMiddleSpanAtHalfProgression() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let id = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/chapter1.xhtml",
            progression: 0.5
        )
        #expect(id == "kobo.3.2")
    }

    @Test func resolvesLastSpanAtOneProgression() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let id = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/chapter1.xhtml",
            progression: 1.0
        )
        #expect(id == "kobo.5.2")
    }

    @Test func returnsNilForChapterWithoutKoboSpans() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let id = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/plain.xhtml",
            progression: 0.5
        )
        #expect(id == nil)
    }

    @Test func returnsNilForMissingChapter() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let id = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/does-not-exist.xhtml",
            progression: 0.5
        )
        #expect(id == nil)
    }

    @Test func cachedSpansSurviveFileDeletion() async throws {
        let env = try await Env.make()
        defer { env.cleanup() }
        let first = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/chapter1.xhtml",
            progression: 0.5
        )
        #expect(first == "kobo.3.2")

        try FileManager.default.removeItem(at: env.bookURL)

        let second = await env.resolver.resolve(
            bookFileURL: env.bookURL,
            chapterHref: "OEBPS/text/chapter1.xhtml",
            progression: 0.5
        )
        #expect(second == "kobo.3.2")
    }

    // MARK: - helpers

    @MainActor
    struct Env {
        let resolver: KEPUBSpanResolver
        let bookURL: URL
        let tmpDir: URL

        static func make() async throws -> Env {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("KEPUBSpanResolverTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let bookURL = tmpDir.appendingPathComponent("book.epub")

            let archive = try await Archive(url: bookURL, accessMode: .create)
            try await Self.addText(archive, path: "OEBPS/text/chapter1.xhtml", text: Self.tenSpanChapter)
            try await Self.addText(archive, path: "OEBPS/text/plain.xhtml", text: Self.plainChapter)

            return Env(resolver: KEPUBSpanResolver(), bookURL: bookURL, tmpDir: tmpDir)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        private static func addText(_ archive: Archive, path: String, text: String) async throws {
            let data = Data(text.utf8)
            try await archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .none,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return data.subdata(in: start..<end)
                }
            )
        }

        static let tenSpanChapter: String = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
        <p><span class="koboSpan" id="kobo.1.1">First.</span> <span class="koboSpan" id="kobo.1.2">Second.</span></p>
        <p><span class="koboSpan" id="kobo.2.1">Third.</span> <span class="koboSpan" id="kobo.2.2">Fourth.</span></p>
        <p><span class="koboSpan" id="kobo.3.1">Fifth.</span> <span class="koboSpan" id="kobo.3.2">Sixth.</span></p>
        <p><span class="koboSpan" id="kobo.4.1">Seventh.</span> <span class="koboSpan" id="kobo.4.2">Eighth.</span></p>
        <p><span class="koboSpan" id="kobo.5.1">Ninth.</span> <span class="koboSpan" id="kobo.5.2">Tenth.</span></p>
        </body>
        </html>
        """

        static let plainChapter: String = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body><p>Plain EPUB content, no koboSpans here.</p></body>
        </html>
        """
    }
}
