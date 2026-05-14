import Testing
import Foundation
import SwiftData
@testable import Kios
import Core

@MainActor
@Suite("BookAnalysisService — basic", .serialized)
struct BookAnalysisServiceBasicsTests {
    @Test("start creates a BookAnalysis row in_progress")
    func startCreatesRow() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        let book = Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub)
        ctx.insert(book)
        try ctx.save()

        let mock = MockLanguageModel()
        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: [:]),
            chaptersFor: { _ in [] }   // zero chapters → returns immediately
        )
        try await service.start(bookID: bookID, engine: .gemma4_e4b)

        let fetched = try ctx.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(fetched.count == 1)
        #expect(fetched.first?.engine == "gemma4_e4b")
    }
}

@MainActor
@Suite("BookAnalysisService — per-chapter", .serialized)
struct BookAnalysisServicePerChapterTests {
    @Test("each chapter's extract response persists CharacterMention rows")
    func extractionPersists() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        ctx.insert(Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub))
        try ctx.save()

        let mock = MockLanguageModel()
        for name in ["Alice", "Bob"] {
            mock.enqueueExtract(.value(
                ChapterCharactersResponse(characters: [
                    ExtractedCharacter(
                        canonicalName: name, aliases: [],
                        descriptionFromChapter: "d", significance: "major",
                        quote: "verbatim quote here"
                    )
                ])
            ))
        }
        // Synthesis pass enqueue is harmless for Task 13 — runSynthesisPass
        // stub doesn't consume a queue entry yet. The Task 14 impl will.
        mock.enqueueExtract(.value(ProfilesSynthesisResponse(profiles: [])))

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: [
                "ch1": "Alice text", "ch2": "Bob text"
            ]),
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1"),
                ChapterRef(index: 1, href: "ch2"),
            ] }
        )
        try await service.startAndAwait(bookID: bookID, engine: .gemma4_e4b)

        let mentions = try ctx.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(mentions.count == 2)
        #expect(Set(mentions.map(\.canonicalName)) == Set(["Alice", "Bob"]))

        let analysis = try ctx.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        )).first
        #expect(analysis?.chaptersCompleted == 2)
    }
}

// MARK: - Test stubs

struct AnalysisStubProvider: AILanguageModelProviding {
    let model: any LanguageModel
    func languageModel(for engine: AIEngine) async throws -> any LanguageModel { model }
}

struct AnalysisStubExtractor: AIChapterTextExtracting {
    let textPerChapter: [String: String]
    func extract(bookID: UUID, chapterHref: String, cutoff: Double?) async throws -> String {
        textPerChapter[chapterHref] ?? ""
    }
}
