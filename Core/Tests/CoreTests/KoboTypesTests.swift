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

    @Test func syncEntryParsesNewEntitlementWithFullMetadata() throws {
        let json = #"""
        [{
          "NewEntitlement": {
            "BookEntitlement": {
              "Id":"u1","CrossRevisionId":"u1","RevisionId":"u1",
              "Accessibility":"Full","Status":"Active","IsRemoved":false,
              "Created":"2026-05-01T00:00:00Z","LastModified":"2026-05-11T00:00:00Z"
            },
            "BookMetadata": {
              "EntitlementId":"u1","Title":"Test Book",
              "Contributors":[{"Name":"Felienne Hermans","Role":"Author"}],
              "CoverImageId":"cov1","Language":"en",
              "DownloadUrls":[
                {"Format":"KEPUB","Url":"https://cwa/d/1/kepub","Size":1024,"Platform":"Generic"}
              ]
            },
            "ReadingState": {
              "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
              "StatusInfo":{"LastModified":"x","Status":"ReadyToRead","TimesStartedReading":0},
              "Statistics":{"LastModified":"x"},
              "CurrentBookmark":{"LastModified":"x"}
            }
          }
        }]
        """#.data(using: .utf8)!

        let entries = try KoboDecoder.decode([KoboSyncEntryOrSkip].self, from: json).compactMap { $0.entry }
        #expect(entries.count == 1)
        guard case .newEntitlement(let ent) = entries[0] else {
            Issue.record("expected newEntitlement"); return
        }
        #expect(ent.bookEntitlement.id == "u1")
        #expect(ent.bookMetadata.title == "Test Book")
        #expect(ent.bookMetadata.contributors == ["Felienne Hermans"])
        #expect(ent.bookMetadata.downloadUrls.first?.format == "KEPUB")
        #expect(ent.bookMetadata.downloadUrls.first?.url.absoluteString == "https://cwa/d/1/kepub")
        #expect(ent.readingState?.entitlementId == "u1")
    }

    @Test func syncEntryParsingTolerantOfMalformedEntitlement() throws {
        // An entitlement whose BookMetadata is missing the required `Title`
        // field should drop *only that entry*, not break the whole array.
        let json = #"""
        [
          { "NewEntitlement": {
              "BookEntitlement":{"Id":"u1","CrossRevisionId":"u1","RevisionId":"u1","Accessibility":"Full","Status":"Active","IsRemoved":false,"Created":"x","LastModified":"x"},
              "BookMetadata":{"EntitlementId":"u1"},
              "ReadingState":null
          }},
          { "DeletedTag": { "Tag": { "Id": "t1", "LastModified": "x" } } }
        ]
        """#.data(using: .utf8)!

        let entries = try KoboDecoder.decode([KoboSyncEntryOrSkip].self, from: json).compactMap { $0.entry }
        #expect(entries.count == 1)
        if case .deletedTag = entries[0] {} else {
            Issue.record("expected deletedTag (malformed entitlement should drop)")
        }
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

    @Test func stateUpdateEncodesCorrectly() throws {
        let update = KoboStateUpdate(readingStates: [
            .init(
                currentBookmark: .init(
                    progressPercent: 45.0,
                    contentSourceProgressPercent: 16.0,
                    location: .init(value: "kobo.10.1", type: "KoboSpan", source: "f_0035.xhtml")
                ),
                statusInfo: .init(status: .reading),
                statistics: nil
            )
        ])
        let data = try JSONEncoder().encode(update)
        let s = String(data: data, encoding: .utf8)!
        #expect(s.contains("\"ReadingStates\":["))
        #expect(s.contains("\"ProgressPercent\":45"))
        #expect(s.contains("\"Value\":\"kobo.10.1\""))
        #expect(s.contains("\"Status\":\"Reading\""))
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
