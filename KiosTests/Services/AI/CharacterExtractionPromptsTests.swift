import Testing
@testable import Kios

@Suite("CharacterExtractionPrompts")
struct CharacterExtractionPromptsTests {
    @Test("character extraction system prompt mentions JSON + significance + quote")
    func extractionPromptShape() {
        let p = CharacterExtractionPrompts.characterExtractionSystem
        #expect(p.contains("character"))
        #expect(p.contains("JSON") || p.contains("json"))
        #expect(p.contains("significance"))
        #expect(p.contains("quote") || p.contains("verbatim"))
    }

    @Test("characters schema describes all five fields")
    func extractionSchemaShape() {
        let s = CharacterExtractionPrompts.charactersSchema
        for field in ["canonicalName", "aliases", "descriptionFromChapter", "significance", "quote"] {
            #expect(s.contains(field), "schema missing field \(field)")
        }
    }

    @Test("profiles schema asks model to echo mentionIDs")
    func profilesSchemaShape() {
        let s = CharacterExtractionPrompts.profilesSchema
        #expect(s.contains("mentionIDs"))
    }
}
