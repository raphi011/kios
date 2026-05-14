import Foundation

/// System prompts and JSON-schema prose for the two-phase character
/// extraction pipeline (per-chapter mentions → cross-chapter synthesis).
///
/// Schema strings are intentionally prose, not formal JSON Schema —
/// instruction-tuned LLMs reliably produce well-formed output when
/// given documentation-style descriptions, less reliably from a
/// strict JSON Schema document. The Foundation Models path ignores
/// these schemas at runtime (its `@Generable` macro handles structure);
/// only the Gemma path appends them to the prompt.
enum CharacterExtractionPrompts {
    static let characterExtractionSystem = """
    You are an assistant that extracts characters from a single chapter \
    of fiction. For each character mentioned in the chapter, produce \
    one record with these fields:

      - canonicalName: the most complete form of the character's name \
        you can confidently determine (e.g. "John Smith" rather than \
        "Smith" or "the doctor"). Use proper-noun capitalization.
      - aliases: every other name, title, or referring form used \
        for this character in this chapter (e.g. ["Smith", "Doctor"]).
      - descriptionFromChapter: a 1-3 sentence description of who this \
        character is, based ONLY on what this chapter reveals. Don't \
        speculate beyond the text.
      - significance: one of "major", "minor", or "mentioned". \
        "major" = appears in scenes / has dialogue; \
        "minor" = referenced in passing but with some context; \
        "mentioned" = name appears once or twice with no detail.
      - quote: a verbatim 10-20 word excerpt from the chapter that \
        contains or surrounds this character's appearance. The quote \
        must appear EXACTLY in the chapter text — it is used to scroll \
        the reader to the passage when the user taps the mention.

    Skip generic referents (he/she/the man/the doctor) unless they are \
    the only form used for an otherwise-unidentified character. Skip \
    quoted speakers when the speaker isn't in this chapter (e.g. \
    quotations from off-stage figures). Reply with ONLY valid JSON.
    """

    static let charactersSchema = """
    {
      "characters": [
        {
          "canonicalName": "string",
          "aliases": ["string"],
          "descriptionFromChapter": "string",
          "significance": "major | minor | mentioned",
          "quote": "string (10-20 words, verbatim from chapter)"
        }
      ]
    }
    """

    static let profileSynthesisSystem = """
    You are an assistant that merges per-chapter character mentions \
    into canonical character profiles for one book.

    You will receive a JSON array of mentions. Each mention has an `id` \
    (UUID), `canonicalName`, `aliases`, `descriptionFromChapter`, and \
    `chapterIndex`. Multiple mentions can refer to the same character \
    (e.g. "Smith" in chapter 1 and "John Smith" in chapter 5 are the \
    same person).

    Group the mentions into canonical character profiles. For each \
    profile, produce:

      - canonicalName: the most complete form across all merged mentions.
      - allAliases: every name or referring form used anywhere.
      - synthesizedDescription: a 2-5 sentence character profile that \
        synthesizes all per-chapter descriptions into one coherent whole. \
        It may include developments across the book.
      - mentionIDs: the array of `id` values from the input mentions that \
        you merged into this profile. EVERY input mention must appear in \
        EXACTLY ONE profile's `mentionIDs`.

    Reply with ONLY valid JSON.
    """

    static let profilesSchema = """
    {
      "profiles": [
        {
          "canonicalName": "string",
          "allAliases": ["string"],
          "synthesizedDescription": "string",
          "mentionIDs": ["uuid-string"]
        }
      ]
    }
    """
}
