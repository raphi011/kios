import Foundation

/// One character mentioned in a single chapter, as produced by the
/// per-chapter extraction pass. The `quote` doubles as the jump anchor
/// at tap time — `Publication.searchService` finds it inside the
/// rendered chapter without needing CFI or KEPUB span markers.
public struct ExtractedCharacter: Codable, Sendable, Hashable {
    public let canonicalName: String
    public let aliases: [String]
    public let descriptionFromChapter: String
    public let significance: String      // "major" / "minor" / "mentioned"
    public let quote: String             // verbatim 10-20 words

    public init(
        canonicalName: String,
        aliases: [String],
        descriptionFromChapter: String,
        significance: String,
        quote: String
    ) {
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.descriptionFromChapter = descriptionFromChapter
        self.significance = significance
        self.quote = quote
    }
}

/// Per-chapter extraction response. Wraps an array so the schema we
/// describe to the model has a stable top-level shape (a JSON object,
/// not a bare array).
public struct ChapterCharactersResponse: Codable, Sendable {
    public let characters: [ExtractedCharacter]

    public init(characters: [ExtractedCharacter]) {
        self.characters = characters
    }
}

/// Canonical character merged from one or more mentions. The
/// `mentionIDs` array is what the synthesis pass returns so the
/// orchestrator can back-link `CharacterMention.profileID` without a
/// second resolution step.
public struct ExtractedProfile: Codable, Sendable, Hashable {
    public let canonicalName: String
    public let allAliases: [String]
    public let synthesizedDescription: String
    public let mentionIDs: [UUID]

    public init(
        canonicalName: String,
        allAliases: [String],
        synthesizedDescription: String,
        mentionIDs: [UUID]
    ) {
        self.canonicalName = canonicalName
        self.allAliases = allAliases
        self.synthesizedDescription = synthesizedDescription
        self.mentionIDs = mentionIDs
    }
}

public struct ProfilesSynthesisResponse: Codable, Sendable {
    public let profiles: [ExtractedProfile]

    public init(profiles: [ExtractedProfile]) {
        self.profiles = profiles
    }
}
