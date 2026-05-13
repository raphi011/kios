import Testing
@testable import Kios
import Core

@Suite("BookFormat")
struct BookFormatTests {

    @Test func mapsEPUBMime() {
        #expect(BookFormat(mimeType: "application/epub+zip") == .epub)
    }

    @Test func mapsPDFMime() {
        #expect(BookFormat(mimeType: "application/pdf") == .pdf)
    }

    @Test func mapsBothCBZMimes() {
        #expect(BookFormat(mimeType: "application/x-cbz") == .cbz)
        #expect(BookFormat(mimeType: "application/vnd.comicbook+zip") == .cbz)
    }

    @Test func mimeMatchingIsCaseInsensitive() {
        #expect(BookFormat(mimeType: "Application/EPUB+Zip") == .epub)
    }

    @Test func returnsNilForUnknownMime() {
        #expect(BookFormat(mimeType: "text/html") == nil)
        #expect(BookFormat(mimeType: "") == nil)
    }

    @Test func fileExtensionMatchesRawValue() {
        #expect(BookFormat.epub.fileExtension == "epub")
        #expect(BookFormat.pdf.fileExtension == "pdf")
        #expect(BookFormat.cbz.fileExtension == "cbz")
    }
}
