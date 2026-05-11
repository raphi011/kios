import Testing
import Foundation
@testable import Core

struct KoboTypesTests {
    @Test func readingStateDecodesFullPayload() throws {
        let json = """
        {
          "EntitlementId": "uuid-1",
          "Created": "2026-05-01T00:00:00Z",
          "LastModified": "2026-05-11T20:36:34Z",
          "PriorityTimestamp": "2026-05-11T20:36:34Z",
          "StatusInfo": {
            "LastModified": "2026-05-11T20:36:34Z",
            "Status": "Reading",
            "TimesStartedReading": 1
          },
          "Statistics": {
            "LastModified": "2026-05-11T20:36:34Z",
            "SpentReadingMinutes": 42,
            "RemainingTimeMinutes": 120
          },
          "CurrentBookmark": {
            "LastModified": "2026-05-11T20:36:34Z",
            "ProgressPercent": 45.0,
            "ContentSourceProgressPercent": 16.0,
            "Location": {
              "Value": "kobo.10.1",
              "Type": "KoboSpan",
              "Source": "f_0035.xhtml"
            }
          }
        }
        """.data(using: .utf8)!

        let state = try KoboDecoder.decode(KoboReadingState.self, from: json)
        #expect(state.entitlementId == "uuid-1")
        #expect(state.statusInfo?.status == .reading)
        #expect(state.currentBookmark?.progressPercent == 45.0)
        #expect(state.currentBookmark?.location?.value == "kobo.10.1")
    }

    @Test func readingStateOmittingOptionalFieldsDecodes() throws {
        let json = """
        {
          "EntitlementId": "uuid-1",
          "Created": "2026-05-01T00:00:00Z",
          "LastModified": "2026-05-11T20:36:34Z",
          "PriorityTimestamp": "2026-05-11T20:36:34Z",
          "StatusInfo": {
            "LastModified": "2026-05-11T20:36:34Z",
            "Status": "ReadyToRead",
            "TimesStartedReading": 0
          },
          "Statistics": { "LastModified": "2026-05-11T20:36:34Z" },
          "CurrentBookmark": { "LastModified": "2026-05-11T20:36:34Z" }
        }
        """.data(using: .utf8)!

        let state = try KoboDecoder.decode(KoboReadingState.self, from: json)
        #expect(state.currentBookmark?.progressPercent == nil)
        #expect(state.currentBookmark?.location == nil)
    }

    @Test func contributorsAsStringArray() throws {
        let json = #"{"Contributors": ["Felienne Hermans", "Jane Doe"]}"#.data(using: .utf8)!
        let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
        #expect(bag.contributors == ["Felienne Hermans", "Jane Doe"])
    }

    @Test func contributorsAsObjectArray() throws {
        let json = #"{"Contributors": [{"Name": "Felienne Hermans", "Role": "Author"}]}"#.data(using: .utf8)!
        let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
        #expect(bag.contributors == ["Felienne Hermans"])
    }

    @Test func contributorsAbsent() throws {
        let json = "{}".data(using: .utf8)!
        let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
        #expect(bag.contributors == [])
    }

    @Test func contributorsNull() throws {
        let json = #"{"Contributors": null}"#.data(using: .utf8)!
        let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
        #expect(bag.contributors == [])
    }

    @Test func syncEntryParsingSkipsStrayStringEntry() throws {
        let json = #"""
        [
          { "ChangedReadingState": { "ReadingState": { "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x","StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},"Statistics":{"LastModified":"x"},"CurrentBookmark":{"LastModified":"x"} } } },
          "ResponseStatus",
          { "DeletedTag": { "Tag": { "Id": "t1", "LastModified": "x" } } },
          { "SomethingUnknown": { "Field": 1 } }
        ]
        """#.data(using: .utf8)!

        let entries = try KoboDecoder.decode([KoboSyncEntryOrSkip].self, from: json).compactMap { $0.entry }
        #expect(entries.count == 2)
        if case .changedReadingState(let rs) = entries[0] {
            #expect(rs.entitlementId == "u1")
        } else {
            Issue.record("expected changedReadingState first")
        }
        if case .deletedTag = entries[1] {
            // good
        } else {
            Issue.record("expected deletedTag second")
        }
    }
}

private struct KoboContributorBag: Decodable {
    let contributors: [String]
    enum CodingKeys: String, CodingKey { case contributors = "Contributors" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contributors = try c.decodeContributors(forKey: .contributors)
    }
}
