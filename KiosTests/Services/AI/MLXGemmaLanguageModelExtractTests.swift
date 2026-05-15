import Testing
import Foundation
import os
@testable import Kios
import Core

@Suite("MLXGemmaLanguageModel.extract", .serialized)
struct MLXGemmaLanguageModelExtractTests {
    /// Stub runner that returns canned text. Doesn't actually load MLX.
    final class StubRunner: ModelRunner {
        let outputs: [String]
        private let index = OSAllocatedUnfairLock<Int>(initialState: 0)
        init(outputs: [String]) { self.outputs = outputs }
        func generate(
            prompt: AIChatPrompt,
            maxNewTokens: Int,
            onToken: @Sendable @escaping (String) -> Void
        ) async throws {
            let out: String = index.withLock { i in
                let v = outputs[i]
                i += 1
                return v
            }
            for char in out { onToken(String(char)) }
        }
    }

    @Test("happy path returns decoded value")
    func happyPath() async throws {
        let json = #"{"characters":[{"canonicalName":"A","aliases":[],"descriptionFromChapter":"d","significance":"minor","quote":"q"}]}"#
        let runner = StubRunner(outputs: [json])
        let model = MLXGemmaLanguageModel(runner: runner)
        let result: ChapterCharactersResponse = try await model.extract(
            ChapterCharactersResponse.self,
            schema: "{schema}",
            system: "sys",
            user: "user"
        )
        #expect(result.characters.count == 1)
        #expect(result.characters[0].canonicalName == "A")
    }

    @Test("malformed first attempt retries and succeeds on second")
    func retrySucceeds() async throws {
        let bad = "this is not JSON"
        let good = #"{"characters":[]}"#
        let runner = StubRunner(outputs: [bad, good])
        let model = MLXGemmaLanguageModel(runner: runner)
        let result: ChapterCharactersResponse = try await model.extract(
            ChapterCharactersResponse.self,
            schema: "{schema}", system: "s", user: "u"
        )
        #expect(result.characters.isEmpty)
    }

    @Test("two malformed attempts throw ExtractionError.malformedOutput")
    func twoFailures() async throws {
        let runner = StubRunner(outputs: ["bad1", "bad2"])
        let model = MLXGemmaLanguageModel(runner: runner)
        await #expect(throws: ExtractionError.self) {
            let _: ChapterCharactersResponse = try await model.extract(
                ChapterCharactersResponse.self,
                schema: "{schema}", system: "s", user: "u"
            )
        }
    }
}
