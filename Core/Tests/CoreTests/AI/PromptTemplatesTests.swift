import Testing
@testable import Core

@Suite("PromptTemplates")
struct PromptTemplatesTests {
    @Test("chapterSummary mentions chapter and body")
    func chapterSummary() {
        let (system, user) = PromptTemplates.chapterSummary(
            chapterTitle: "The Beginning",
            bookTitle: "The Great Book",
            body: "Once upon a time..."
        )
        #expect(system.contains("summary"))
        #expect(user.contains("The Beginning"))
        #expect(user.contains("Once upon a time"))
    }

    @Test("mapStep prompts mention chapter title")
    func mapStep() {
        let (system, user) = PromptTemplates.mapStep(chunk: "chunk text", chapterTitle: "Ch1")
        #expect(!system.isEmpty)
        #expect(user.contains("Ch1"))
        #expect(user.contains("chunk text"))
    }

    @Test("reduceStep combines partial summaries")
    func reduceStep() {
        let partials = ["Part 1 happened.", "Part 2 happened.", "Part 3 happened."]
        let (system, user) = PromptTemplates.reduceStep(partials: partials, chapterTitle: "Ch1")
        #expect(!system.isEmpty)
        for partial in partials {
            #expect(user.contains(partial))
        }
    }

    @Test("selectionQuestion grounds model to passage")
    func selectionQuestion() {
        let (system, user) = PromptTemplates.selectionQuestion(
            selection: "the selected text",
            question: "what does this mean?",
            bookTitle: "Book",
            chapterTitle: "Chapter"
        )
        #expect(system.localizedCaseInsensitiveContains("passage") || system.localizedCaseInsensitiveContains("only"))
        #expect(user.contains("the selected text"))
        #expect(user.contains("what does this mean?"))
    }
}
