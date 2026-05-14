import Testing
@testable import Kios
import Core
import SwiftData
import Foundation

@Suite("AISummaryService")
struct AISummaryServiceTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([ChapterSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    @Test("summarizeCurrentChapter streams and persists with engine column")
    @MainActor
    func streamsAndPersists() async throws {
        let ctx = try makeContext()
        let mock = MockLanguageModel(
            contextBudgetCharacters: 1_000,
            responses: [.streamChunks(["Hello ", "world."], delayPerChunk: .milliseconds(1))]
        )
        let service = AISummaryService(
            modelContext: ctx,
            modelProvider: MockModelProvider(model: mock),
            textExtractor: StubExtractor(text: "Body.")
        )
        let bookID = UUID()
        await service.summarizeCurrentChapter(
            bookID: bookID,
            chapterHref: "ch1",
            chapterTitle: "Ch1",
            cutoff: nil,
            scope: .full,
            engine: .gemma4_e4b
        )
        guard case .done(let text) = service.summaryState else {
            Issue.record("expected .done; got \(service.summaryState)")
            return
        }
        #expect(text == "Hello world.")
        let rows = try ctx.fetch(FetchDescriptor<ChapterSummary>())
        #expect(rows.count == 1)
        #expect(rows.first?.engine == "gemma4_e4b")
    }

    @Test("cache hit returns cached text without calling model")
    @MainActor
    func cacheHit() async throws {
        let ctx = try makeContext()
        let mock = MockLanguageModel(responses: [.fail(TestError.shouldNotBeCalled)])
        let bookID = UUID()
        let cached = ChapterSummary(
            id: ChapterSummary.makeID(bookID: bookID, chapterHref: "ch1", scope: .full, engine: .gemma4_e4b),
            bookID: bookID,
            chapterHref: "ch1",
            scope: SummaryScope.full.rawValue,
            engine: AIEngine.gemma4_e4b.rawValue,
            text: "Cached text.",
            createdAt: Date(),
            sourceHash: ModelAssetStore.sha256Hex(of: Data("Body.".utf8))
        )
        ctx.insert(cached)
        try ctx.save()
        let service = AISummaryService(
            modelContext: ctx,
            modelProvider: MockModelProvider(model: mock),
            textExtractor: StubExtractor(text: "Body.")
        )
        await service.summarizeCurrentChapter(
            bookID: bookID, chapterHref: "ch1", chapterTitle: "Ch1",
            cutoff: nil, scope: .full, engine: .gemma4_e4b
        )
        guard case .done(let text) = service.summaryState else {
            Issue.record("expected .done; got \(service.summaryState)")
            return
        }
        #expect(text == "Cached text.")
        #expect(mock.calls.isEmpty)
    }

    @Test("hash mismatch regenerates and overwrites cache")
    @MainActor
    func hashMismatch() async throws {
        let ctx = try makeContext()
        let mock = MockLanguageModel(responses: [.streamChunks(["Fresh."], delayPerChunk: .milliseconds(1))])
        let bookID = UUID()
        let stale = ChapterSummary(
            id: ChapterSummary.makeID(bookID: bookID, chapterHref: "ch1", scope: .full, engine: .gemma4_e4b),
            bookID: bookID, chapterHref: "ch1",
            scope: SummaryScope.full.rawValue, engine: AIEngine.gemma4_e4b.rawValue,
            text: "Stale.", createdAt: Date(),
            sourceHash: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        ctx.insert(stale)
        try ctx.save()
        let service = AISummaryService(
            modelContext: ctx,
            modelProvider: MockModelProvider(model: mock),
            textExtractor: StubExtractor(text: "Body.")
        )
        await service.summarizeCurrentChapter(
            bookID: bookID, chapterHref: "ch1", chapterTitle: "Ch1",
            cutoff: nil, scope: .full, engine: .gemma4_e4b
        )
        guard case .done(let text) = service.summaryState else {
            Issue.record("expected .done; got \(service.summaryState)")
            return
        }
        #expect(text == "Fresh.")
        #expect(mock.calls.count == 1)
    }

    @Test("engine-specific cache: same chapter, different engines, separate rows")
    @MainActor
    func engineSeparateCache() async throws {
        let ctx = try makeContext()
        let mock1 = MockLanguageModel(responses: [.streamChunks(["A."], delayPerChunk: .milliseconds(1))])
        let provider = MockModelProvider(model: mock1)
        let service = AISummaryService(
            modelContext: ctx, modelProvider: provider,
            textExtractor: StubExtractor(text: "Body.")
        )
        let bookID = UUID()
        await service.summarizeCurrentChapter(
            bookID: bookID, chapterHref: "ch1", chapterTitle: "Ch1",
            cutoff: nil, scope: .full, engine: .gemma4_e4b
        )
        let mock2 = MockLanguageModel(responses: [.streamChunks(["B."], delayPerChunk: .milliseconds(1))])
        provider.model = mock2
        await service.summarizeCurrentChapter(
            bookID: bookID, chapterHref: "ch1", chapterTitle: "Ch1",
            cutoff: nil, scope: .full, engine: .foundationModels
        )
        let rows = try ctx.fetch(FetchDescriptor<ChapterSummary>())
        #expect(rows.count == 2)
        #expect(Set(rows.map { $0.engine }) == Set(["gemma4_e4b", "foundationModels"]))
    }
}

private enum TestError: Error { case shouldNotBeCalled }

private final class MockModelProvider: AILanguageModelProviding, @unchecked Sendable {
    var model: any LanguageModel
    init(model: any LanguageModel) { self.model = model }
    func languageModel(for engine: AIEngine) async throws -> any LanguageModel { model }
}

private struct StubExtractor: AIChapterTextExtracting {
    let text: String
    func extract(bookID: UUID, chapterHref: String, cutoff: Double?) async throws -> String { text }
}
