import Testing
import Foundation
@testable import Core

struct KoboSpanParserTests {

    private static let fixture: String = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
    <head>
      <title>Chapter One</title>
      <link rel="stylesheet" href="../css/style.css" type="text/css"/>
    </head>
    <body>
      <div class="chapter">
        <h1 id="ch1"><span class="koboSpan" id="kobo.1.1">Chapter One</span></h1>
        <p>
          <span class="koboSpan" id="kobo.2.1">It was the best of times,</span>
          <span class="koboSpan" id="kobo.2.2"> it was the worst of times,</span>
          <span class="koboSpan" id="kobo.2.3"> it was the age of wisdom,</span>
        </p>
        <p>
          <span class="koboSpan" id="kobo.3.1">it was the age of foolishness,</span>
          <span class="koboSpan" id="kobo.3.2"> it was the epoch of belief,</span>
        </p>
        <p>
          <span class="koboSpan" id="kobo.4.1">it was the epoch of incredulity,</span>
          <span class="koboSpan" id="kobo.4.2"> it was the season of Light,</span>
        </p>
        <p>
          <span class="koboSpan" id="kobo.5.1">it was the season of Darkness,</span>
          <span class="koboSpan" id="kobo.5.2"> it was the spring of hope.</span>
        </p>
        <!-- not a koboSpan: regular span with different class -->
        <p><span class="footnote" id="fn1">[1]</span></p>
      </div>
    </body>
    </html>
    """

    @Test func extractsAllIdsInDocumentOrder() {
        let ids = KoboSpanParser.spans(in: Self.fixture)
        #expect(ids == [
            "kobo.1.1",
            "kobo.2.1", "kobo.2.2", "kobo.2.3",
            "kobo.3.1", "kobo.3.2",
            "kobo.4.1", "kobo.4.2",
            "kobo.5.1", "kobo.5.2",
        ])
    }

    @Test func returnsEmptyForPlainXhtml() {
        let plain = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Plain</title></head>
        <body>
          <h1>Chapter</h1>
          <p>No koboSpans here. Just <em>regular</em> markup.</p>
          <p><span class="emphasis">Even ordinary spans don't count.</span></p>
        </body>
        </html>
        """
        #expect(KoboSpanParser.spans(in: plain).isEmpty)
    }

    @Test func handlesAttributeOrdering() {
        let classFirst = #"<span class="koboSpan" id="kobo.1.1">Hello</span>"#
        let idFirst = #"<span id="kobo.2.2" class="koboSpan">World</span>"#
        let mixed = """
        \(classFirst)
        \(idFirst)
        """

        #expect(KoboSpanParser.spans(in: classFirst) == ["kobo.1.1"])
        #expect(KoboSpanParser.spans(in: idFirst) == ["kobo.2.2"])
        #expect(KoboSpanParser.spans(in: mixed) == ["kobo.1.1", "kobo.2.2"])
    }

    @Test func ignoresNonSpanElementsWithKoboSpanClass() {
        let xhtml = #"""
        <div class="koboSpan" id="kobo.99.99">not a span</div>
        <span class="koboSpan" id="kobo.1.1">yes</span>
        """#
        #expect(KoboSpanParser.spans(in: xhtml) == ["kobo.1.1"])
    }

    @Test func deduplicatesKeepingFirstOccurrence() {
        let xhtml = #"""
        <span class="koboSpan" id="kobo.1.1">a</span>
        <span class="koboSpan" id="kobo.1.2">b</span>
        <span class="koboSpan" id="kobo.1.1">duplicate</span>
        """#
        #expect(KoboSpanParser.spans(in: xhtml) == ["kobo.1.1", "kobo.1.2"])
    }

    // MARK: - span(at:in:)

    private static let tenSpans: [String] = (1...10).map { "kobo.1.\($0)" }

    @Test func spanAtZeroReturnsFirst() {
        #expect(KoboSpanParser.span(at: 0.0, in: Self.tenSpans) == "kobo.1.1")
    }

    @Test func spanAtOneReturnsLast() {
        #expect(KoboSpanParser.span(at: 1.0, in: Self.tenSpans) == "kobo.1.10")
    }

    @Test func spanAtMiddleReturnsIndexFive() {
        #expect(KoboSpanParser.span(at: 0.5, in: Self.tenSpans) == "kobo.1.6")
    }

    @Test func spanAtOutOfRangeClamps() {
        #expect(KoboSpanParser.span(at: -1.0, in: Self.tenSpans) == "kobo.1.1")
        #expect(KoboSpanParser.span(at: 2.0, in: Self.tenSpans) == "kobo.1.10")
    }

    @Test func spanOnEmptyReturnsNil() {
        #expect(KoboSpanParser.span(at: 0.0, in: []) == nil)
        #expect(KoboSpanParser.span(at: 0.5, in: []) == nil)
        #expect(KoboSpanParser.span(at: 1.0, in: []) == nil)
    }
}
