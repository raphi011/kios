import Testing
import Foundation
@testable import Core

@Suite("MockLanguageModel.extract")
struct MockLanguageModelExtractTests {
    @Test("returns enqueued typed value")
    func returnsValue() async throws {
        let mock = MockLanguageModel()
        let expected = ChapterCharactersResponse(characters: [
            ExtractedCharacter(canonicalName: "X", aliases: [],
                               descriptionFromChapter: "d",
                               significance: "minor", quote: "q")
        ])
        mock.enqueueExtract(.value(expected))
        let result: ChapterCharactersResponse = try await mock.extract(
            ChapterCharactersResponse.self,
            schema: "shape",
            system: "sys",
            user: "user"
        )
        #expect(result == expected)
    }

    @Test("throws enqueued error")
    func throwsError() async throws {
        let mock = MockLanguageModel()
        struct Boom: Error, Equatable {}
        mock.enqueueExtract(.fail(Boom()))
        await #expect(throws: Boom.self) {
            let _: ChapterCharactersResponse = try await mock.extract(
                ChapterCharactersResponse.self,
                schema: "", system: "", user: ""
            )
        }
    }

    @Test("throws when no response is queued")
    func throwsWhenEmpty() async throws {
        let mock = MockLanguageModel()
        await #expect(throws: ExtractionError.self) {
            let _: ChapterCharactersResponse = try await mock.extract(
                ChapterCharactersResponse.self,
                schema: "", system: "", user: ""
            )
        }
    }
}

extension ChapterCharactersResponse: Equatable {
    public static func == (lhs: ChapterCharactersResponse, rhs: ChapterCharactersResponse) -> Bool {
        lhs.characters == rhs.characters
    }
}
