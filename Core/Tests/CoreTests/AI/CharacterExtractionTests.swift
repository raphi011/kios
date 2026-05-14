import Testing
import Foundation
@testable import Core

@Suite("CharacterExtraction DTOs")
struct CharacterExtractionTests {
    @Test("ExtractedCharacter round-trips through JSONEncoder/Decoder")
    func extractedCharacterRoundTrip() throws {
        let original = ExtractedCharacter(
            canonicalName: "John Smith",
            aliases: ["Smith", "Doctor"],
            descriptionFromChapter: "A weary traveller.",
            significance: "major",
            quote: "Smith stepped off the train at dusk."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExtractedCharacter.self, from: data)
        #expect(decoded == original)
    }

    @Test("ChapterCharactersResponse decodes from typical model JSON")
    func chapterResponseDecodes() throws {
        let json = """
        {"characters":[{"canonicalName":"X","aliases":[],"descriptionFromChapter":"d","significance":"minor","quote":"q"}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ChapterCharactersResponse.self, from: json)
        #expect(resp.characters.count == 1)
        #expect(resp.characters[0].canonicalName == "X")
    }

    @Test("ExtractedProfile mentionIDs round-trip preserves UUIDs")
    func profileMentionIDsRoundTrip() throws {
        let id1 = UUID()
        let id2 = UUID()
        let original = ExtractedProfile(
            canonicalName: "C",
            allAliases: ["a", "b"],
            synthesizedDescription: "s",
            mentionIDs: [id1, id2]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExtractedProfile.self, from: data)
        #expect(decoded.mentionIDs == [id1, id2])
    }
}
