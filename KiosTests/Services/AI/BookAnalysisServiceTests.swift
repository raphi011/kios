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
