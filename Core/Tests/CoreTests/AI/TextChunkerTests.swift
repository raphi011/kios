import Testing
@testable import Core

@Suite("TextChunker")
struct TextChunkerTests {
    @Test("short text returns single chunk equal to input")
    func shortInputSingleChunk() {
        let chunker = TextChunker(budgetCharacters: 1000, overlapCharacters: 50)
        let input = "Hello world. This is short."
        let chunks = chunker.chunks(of: input)
        #expect(chunks == [input])
    }

    @Test("input exactly at budget returns single chunk")
    func atBudget() {
        let chunker = TextChunker(budgetCharacters: 100, overlapCharacters: 10)
        let input = String(repeating: "a", count: 100)
        #expect(chunker.chunks(of: input).count == 1)
    }

    @Test("multi-paragraph text splits on paragraph boundary")
    func paragraphSplit() {
        let chunker = TextChunker(budgetCharacters: 50, overlapCharacters: 10)
        let p1 = "Paragraph one is about forty characters."  // 40 chars
        let p2 = "Paragraph two is about forty characters."  // 40 chars
        let input = p1 + "\n\n" + p2
        let chunks = chunker.chunks(of: input)
        #expect(chunks.count == 2)
        #expect(chunks[0].contains("Paragraph one"))
        #expect(chunks[1].contains("Paragraph two"))
    }

    @Test("single huge paragraph splits on sentence boundary")
    func sentenceSplit() {
        let chunker = TextChunker(budgetCharacters: 30, overlapCharacters: 5)
        let input = "First sentence here. Second sentence here. Third sentence here."
        let chunks = chunker.chunks(of: input)
        #expect(chunks.count >= 2)
        for chunk in chunks {
            #expect(chunk.count <= 60)
        }
    }

    @Test("no boundary in budget falls back to hard cut")
    func hardCut() {
        let chunker = TextChunker(budgetCharacters: 20, overlapCharacters: 5)
        let input = String(repeating: "a", count: 100)
        let chunks = chunker.chunks(of: input)
        #expect(chunks.count >= 4)
    }

    @Test("overlap preserves context between chunks")
    func overlap() {
        let chunker = TextChunker(budgetCharacters: 30, overlapCharacters: 10)
        let input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA. BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB."
        let chunks = chunker.chunks(of: input)
        if chunks.count >= 2 {
            let combined = chunks.joined()
            #expect(combined.count >= input.count)
        }
    }
}
