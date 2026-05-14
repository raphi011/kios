// Kios/Services/AI/FoundationModelsExtraction.swift
import Foundation
import Core

#if canImport(FoundationModels)
import FoundationModels

/// FM `@Generable` mirrors of the Codable extraction DTOs defined in
/// `Core/Sources/Core/AI/Models/CharacterExtraction.swift`. The two
/// universes exist because `@Generable` is iOS 26+, but the project
/// deployment target is iOS 17 — making the Core types `@Generable`
/// would gate all of `Core/AI/...` behind iOS 26. Bidirectional
/// mappers below keep the two in sync.

@available(iOS 26, *)
@Generable
struct FMExtractedCharacter {
    @Guide(description: "Most complete form of the character's name (e.g. 'John Smith' rather than 'Smith').")
    let canonicalName: String
    @Guide(description: "Every other name, title, or referring form used in this chapter.")
    let aliases: [String]
    @Guide(description: "1-3 sentence description of who this character is, based on what this chapter reveals.")
    let descriptionFromChapter: String
    @Guide(description: "Exactly one of: major, minor, mentioned.")
    let significance: String
    @Guide(description: "Verbatim 10-20 word excerpt from the chapter where this character appears.")
    let quote: String
}

@available(iOS 26, *)
@Generable
struct FMChapterCharactersResponse {
    @Guide(description: "Array of characters found in the chapter.")
    let characters: [FMExtractedCharacter]
}

@available(iOS 26, *)
@Generable
struct FMExtractedProfile {
    @Guide(description: "Most complete form of the canonical name across all merged mentions.")
    let canonicalName: String
    @Guide(description: "Every alias or referring form used across all merged mentions.")
    let allAliases: [String]
    @Guide(description: "2-5 sentence character profile synthesizing all per-chapter descriptions.")
    let synthesizedDescription: String
    @Guide(description: "UUID strings of the input mentions you merged into this profile.")
    let mentionIDs: [String]
}

@available(iOS 26, *)
@Generable
struct FMProfilesSynthesisResponse {
    @Guide(description: "Canonical character profiles synthesized from the input mentions.")
    let profiles: [FMExtractedProfile]
}

// MARK: - Mappers

@available(iOS 26, *)
extension ChapterCharactersResponse {
    init(_ fm: FMChapterCharactersResponse) {
        self.init(characters: fm.characters.map {
            ExtractedCharacter(
                canonicalName: $0.canonicalName,
                aliases: $0.aliases,
                descriptionFromChapter: $0.descriptionFromChapter,
                significance: $0.significance,
                quote: $0.quote
            )
        })
    }
}

@available(iOS 26, *)
extension ProfilesSynthesisResponse {
    init(_ fm: FMProfilesSynthesisResponse) {
        self.init(profiles: fm.profiles.map {
            ExtractedProfile(
                canonicalName: $0.canonicalName,
                allAliases: $0.allAliases,
                synthesizedDescription: $0.synthesizedDescription,
                mentionIDs: $0.mentionIDs.compactMap(UUID.init(uuidString:))
            )
        })
    }
}
#endif
