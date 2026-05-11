import Testing
import Foundation
@testable import Core

@Suite("KOSyncProgressMapper")
struct KOSyncProgressMapperTests {

    @Test func encodeOurFormat() {
        #expect(KOSyncProgressMapper.encodeProgress(chapter: 5, intraProgression: 0.4231) == "5:0.4231")
    }

    @Test func encodeClampsLowerBound() {
        #expect(KOSyncProgressMapper.encodeProgress(chapter: 0, intraProgression: -0.1) == "0:0.0000")
    }

    @Test func encodeClampsUpperBound() {
        #expect(KOSyncProgressMapper.encodeProgress(chapter: 99, intraProgression: 1.5) == "99:1.0000")
    }

    @Test func encodeUsesFourDecimals() {
        #expect(KOSyncProgressMapper.encodeProgress(chapter: 0, intraProgression: 0.5) == "0:0.5000")
    }

    @Test func encodeIsLocaleIndependent() {
        // %.4f with String(format:) uses C locale — comma-decimal locales
        // shouldn't change the output.
        #expect(KOSyncProgressMapper.encodeProgress(chapter: 0, intraProgression: 0.42) == "0:0.4200")
    }

    @Test func decodeRoundTripsOurFormat() throws {
        let encoded = KOSyncProgressMapper.encodeProgress(chapter: 12, intraProgression: 0.0)
        let (chapter, prog) = try KOSyncProgressMapper.decodeProgress(encoded)
        #expect(chapter == 12)
        #expect(prog == 0.0)
    }

    @Test func decodeRoundTripsOurFormatNonZero() throws {
        let (chapter, prog) = try KOSyncProgressMapper.decodeProgress("7:0.6543")
        #expect(chapter == 7)
        #expect(prog == 0.6543)
    }

    @Test func decodeKOReaderXPointerExtractsChapter() throws {
        let (chapter, prog) = try KOSyncProgressMapper.decodeProgress(
            "/body/DocFragment[3]/body/p[12]/text().42"
        )
        // 1-indexed in xpointer → 0-indexed in our scheme.
        #expect(chapter == 2)
        #expect(prog == 0)
    }

    @Test func decodeKOReaderFirstFragment() throws {
        let (chapter, _) = try KOSyncProgressMapper.decodeProgress("/body/DocFragment[1]/body/h1[1]")
        #expect(chapter == 0)
    }

    @Test func decodeUnknownFormatThrows() {
        #expect(throws: KOSyncProgressMapper.Error.unparsable("garbage:::nope")) {
            _ = try KOSyncProgressMapper.decodeProgress("garbage:::nope")
        }
    }

    @Test func decodeOutOfRangeProgressionThrows() {
        // chapter parses, progression is > 1 — should NOT match our format
        // (would return nil), should NOT match xpointer (no DocFragment),
        // so falls through to throw.
        #expect(throws: KOSyncProgressMapper.Error.self) {
            _ = try KOSyncProgressMapper.decodeProgress("5:1.5")
        }
    }

    @Test func decodeMalformedChapterThrows() {
        #expect(throws: KOSyncProgressMapper.Error.self) {
            _ = try KOSyncProgressMapper.decodeProgress("abc:0.5")
        }
    }

    @Test func decodeXPointerWithoutDocFragmentThrows() {
        #expect(throws: KOSyncProgressMapper.Error.self) {
            _ = try KOSyncProgressMapper.decodeProgress("/body/p[1]/text().0")
        }
    }
}
