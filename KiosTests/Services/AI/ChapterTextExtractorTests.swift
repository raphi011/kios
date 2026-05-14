import Testing
import Foundation
import ReadiumShared
import ReadiumStreamer
@testable import Kios

@Suite("ChapterTextExtractor", .serialized)
struct ChapterTextExtractorTests {

    /// Opens `sample-chapter.epub` from the test bundle and returns the
    /// publication + its first reading-order link (chapter 1).
    private func openFixture() async throws -> (publication: Publication, firstLink: Link) {
        let bundle = Bundle(for: TestBundleClass.self)
        let url = try #require(
            bundle.url(forResource: "sample-chapter", withExtension: "epub"),
            "missing fixture sample-chapter.epub"
        )

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        let fileURL = try #require(FileURL(url: url), "FileURL rejected fixture URL")
        let asset: Asset = try await assetRetriever.retrieve(url: fileURL).get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)
        let publication: Publication = try await opener
            .open(asset: asset, allowUserInteraction: false)
            .get()

        let link = try #require(publication.readingOrder.first, "fixture has no reading order")
        return (publication, link)
    }

    @Test("full chapter extraction yields non-empty plain text")
    func fullExtract() async throws {
        let (pub, link) = try await openFixture()
        let extractor = ChapterTextExtractor(publication: pub)
        let text = try await extractor.extract(link: link, cutoff: nil)
        #expect(text.count > 100)
        #expect(!text.contains("<"))
        #expect(!text.contains("&lt;"))
        // Script content must be gone.
        #expect(!text.contains("console.log"))
    }

    @Test("cutoff 0.5 yields about half the text, aligned to paragraph")
    func halfCutoff() async throws {
        let (pub, link) = try await openFixture()
        let extractor = ChapterTextExtractor(publication: pub)
        let full = try await extractor.extract(link: link, cutoff: nil)
        let half = try await extractor.extract(link: link, cutoff: 0.5)
        #expect(half.count < full.count)
        #expect(half.count > Int(Double(full.count) * 0.3))
        #expect(half.count < Int(Double(full.count) * 0.7))
        let last = half.last
        #expect(last == "\n" || last == "." || last == "!" || last == "?" || last == nil)
    }

    @Test("htmlToPlain strips tags, decodes entities, normalizes whitespace")
    func htmlToPlainUnit() {
        let html = """
        <html><head><script>var x=1;</script><style>p{color:red}</style></head>
        <body><h1>Title</h1>\
        <p>First &amp; foremost.</p>\
        <p>Line one<br/>Line two</p>\
        <p>&mdash;end&nbsp;here&hellip;</p>\
        </body></html>
        """
        let plain = ChapterTextExtractor.htmlToPlain(html)
        #expect(!plain.contains("<"))
        #expect(!plain.contains("var x"))
        #expect(!plain.contains("color:red"))
        #expect(plain.contains("First & foremost."))
        #expect(plain.contains("Line one\nLine two"))
        #expect(plain.contains("—end here…"))
    }
}

private final class TestBundleClass {}
