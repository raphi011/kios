import Testing
import Foundation
import os
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
            summaryHelper: StubSummaryHelper(),
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

        // `complete(...)` is consumed by `runBookSummaryPass` after the
        // per-chapter loop. One streamed response is enough — the queue clamps.
        let mock = MockLanguageModel(responses: [
            .streamChunks(["Book summary."], delayPerChunk: .milliseconds(1))
        ])
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
        mock.enqueueExtract(.value(ProfilesSynthesisResponse(profiles: [])))

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: [
                "ch1": "Alice text", "ch2": "Bob text"
            ]),
            summaryHelper: StubSummaryHelper(),
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1", title: "Chapter 1"),
                ChapterRef(index: 1, href: "ch2", title: "Chapter 2"),
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

@MainActor
@Suite("BookAnalysisService — synthesis", .serialized)
struct BookAnalysisServiceSynthesisTests {
    @Test("synthesis pass writes CharacterProfile rows + back-links mentions")
    func synthesisLinks() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        ctx.insert(Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub))
        try ctx.save()

        let mock = MockLanguageModel(responses: [
            .streamChunks(["Book summary."], delayPerChunk: .milliseconds(1))
        ])
        mock.enqueueExtract(.value(ChapterCharactersResponse(characters: [
            ExtractedCharacter(canonicalName: "Alice", aliases: [],
                               descriptionFromChapter: "d", significance: "major",
                               quote: "alice quote")
        ])))
        mock.enqueueExtract(.value(ChapterCharactersResponse(characters: [
            ExtractedCharacter(canonicalName: "Bob", aliases: [],
                               descriptionFromChapter: "d", significance: "minor",
                               quote: "bob quote")
        ])))
        // For the synthesis call, dynamically resolve actual mention IDs by
        // hopping to MainActor to read SwiftData.
        mock.setExtractInterceptor { type, _, _ in
            if type == ProfilesSynthesisResponse.self {
                let resolved: ProfilesSynthesisResponse? = await MainActor.run {
                    let mentions = (try? ctx.fetch(FetchDescriptor<CharacterMention>(
                        predicate: #Predicate { $0.bookID == bookID }
                    ))) ?? []
                    guard let alice = mentions.first(where: { $0.canonicalName == "Alice" })?.id,
                          let bob = mentions.first(where: { $0.canonicalName == "Bob" })?.id
                    else { return nil }
                    return ProfilesSynthesisResponse(profiles: [
                        ExtractedProfile(canonicalName: "Alice", allAliases: [],
                                         synthesizedDescription: "A.",
                                         mentionIDs: [alice]),
                        ExtractedProfile(canonicalName: "Bob", allAliases: [],
                                         synthesizedDescription: "B.",
                                         mentionIDs: [bob])
                    ])
                }
                return resolved
            }
            return nil
        }

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: ["ch1": "a", "ch2": "b"]),
            summaryHelper: StubSummaryHelper(),
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1", title: "Chapter 1"),
                ChapterRef(index: 1, href: "ch2", title: "Chapter 2"),
            ] }
        )
        try await service.startAndAwait(bookID: bookID, engine: .gemma4_e4b)

        let profiles = try ctx.fetch(FetchDescriptor<CharacterProfile>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(profiles.count == 2)
        let mentions = try ctx.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(mentions.allSatisfy { $0.profileID != nil })

        let analysis = try ctx.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        )).first
        #expect(analysis?.status == "completed")
    }
}

@MainActor
@Suite("BookAnalysisService — cancellation + resume", .serialized)
struct BookAnalysisServiceCancellationTests {
    @Test("cancel mid-run preserves completed mentions and marks failed")
    func cancelPreservesPartial() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        ctx.insert(Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub))
        try ctx.save()

        let mock = MockLanguageModel()
        // First call returns immediately via interceptor; subsequent calls
        // stall until cancellation. (Queueing won't work here because the
        // interceptor runs before the queue is consulted.)
        let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        mock.setExtractInterceptor { _, _, _ in
            let call = counter.withLock { n -> Int in
                n += 1
                return n
            }
            if call == 1 {
                return ChapterCharactersResponse(characters: [
                    ExtractedCharacter(canonicalName: "A", aliases: [],
                                       descriptionFromChapter: "d", significance: "minor",
                                       quote: "q")
                ])
            }
            try await Task.sleep(for: .seconds(30))
            return nil
        }

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: ["ch1": "a", "ch2": "b"]),
            summaryHelper: StubSummaryHelper(),
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1", title: "Chapter 1"),
                ChapterRef(index: 1, href: "ch2", title: "Chapter 2"),
            ] }
        )
        try await service.start(bookID: bookID, engine: .gemma4_e4b)
        try await Task.sleep(for: .milliseconds(200))
        service.cancel()
        await service.taskValue()

        let mentions = try ctx.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(mentions.count == 1)
        let row = try ctx.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        )).first
        #expect(row?.status == "failed")
        #expect(row?.failureReason == "Canceled")
    }

    @Test("resume re-runs only missing chapters")
    func resumeOnlyMissing() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        ctx.insert(Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub))
        let row = BookAnalysis(bookID: bookID, engine: "gemma4_e4b", chaptersTotal: 3,
                               status: "failed", chaptersCompleted: 1,
                               failureReason: "Canceled")
        ctx.insert(row)
        ctx.insert(CharacterMention(
            id: UUID(), bookID: bookID, chapterIndex: 0, chapterHref: "ch1",
            canonicalName: "Alice", aliasesInChapter: [],
            descriptionFromChapter: "d", significance: "major",
            quote: "q", profileID: nil
        ))
        try ctx.save()

        let mock = MockLanguageModel(responses: [
            .streamChunks(["Book summary."], delayPerChunk: .milliseconds(1))
        ])
        mock.enqueueExtract(.value(ChapterCharactersResponse(characters: [
            ExtractedCharacter(canonicalName: "Bob", aliases: [],
                               descriptionFromChapter: "d", significance: "minor",
                               quote: "q")
        ])))
        mock.enqueueExtract(.value(ChapterCharactersResponse(characters: [
            ExtractedCharacter(canonicalName: "Carol", aliases: [],
                               descriptionFromChapter: "d", significance: "minor",
                               quote: "q")
        ])))
        mock.enqueueExtract(.value(ProfilesSynthesisResponse(profiles: [])))

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: [
                "ch1": "a", "ch2": "b", "ch3": "c"
            ]),
            summaryHelper: StubSummaryHelper(),
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1", title: "Chapter 1"),
                ChapterRef(index: 1, href: "ch2", title: "Chapter 2"),
                ChapterRef(index: 2, href: "ch3", title: "Chapter 3"),
            ] }
        )
        try await service.resumeAndAwait(bookID: bookID, engine: .gemma4_e4b)

        let mentions = try ctx.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(Set(mentions.map(\.canonicalName)) == Set(["Alice", "Bob", "Carol"]))
    }
}

@MainActor
@Suite("BookAnalysisService — book summary", .serialized)
struct BookAnalysisServiceBookSummaryTests {
    @Test("book-summary pass persists a BookSummary row")
    func bookSummaryWritten() async throws {
        let container = try ModelContainer.kiosInMemory()
        let ctx = container.mainContext
        let bookID = UUID()
        ctx.insert(Book(source: .local, id: bookID, title: "T", authors: ["A"], format: .epub))
        try ctx.save()

        let mock = MockLanguageModel(responses: [
            .streamChunks(["Whole-book synopsis."], delayPerChunk: .milliseconds(1))
        ])
        mock.enqueueExtract(.value(ChapterCharactersResponse(characters: [])))
        mock.enqueueExtract(.value(ProfilesSynthesisResponse(profiles: [])))

        let service = BookAnalysisService(
            modelContext: ctx,
            provider: AnalysisStubProvider(model: mock),
            extractor: AnalysisStubExtractor(textPerChapter: ["ch1": "a"]),
            summaryHelper: StubSummaryHelper(modelContext: ctx),
            chaptersFor: { _ in [ChapterRef(index: 0, href: "ch1", title: "Chapter 1")] }
        )
        try await service.startAndAwait(bookID: bookID, engine: .gemma4_e4b)

        let summaries = try ctx.fetch(FetchDescriptor<BookSummary>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(summaries.count == 1)
        #expect(summaries.first?.text == "Whole-book synopsis.")

        let chapterSummaries = try ctx.fetch(FetchDescriptor<ChapterSummary>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(chapterSummaries.count == 1)
        #expect(chapterSummaries.first?.text == "summary of ch1")
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

@MainActor
final class StubSummaryHelper: AISummaryServiceHelping {
    /// Optional context: when set, the stub persists `ChapterSummary` rows
    /// to match the real `AISummaryService.generateChapterSummary` behavior
    /// so the book-summary pass has rows to concatenate. Tests that don't
    /// care about the downstream pass leave it nil and only the returned
    /// String is observed.
    let modelContext: ModelContext?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    func generateChapterSummary(
        bookID: UUID, chapterHref: String, chapterTitle: String,
        engine: AIEngine, model: any LanguageModel
    ) async throws -> String {
        let text = "summary of \(chapterHref)"
        if let ctx = modelContext {
            let id = ChapterSummary.makeID(bookID: bookID, chapterHref: chapterHref, engine: engine)
            let row = ChapterSummary(
                id: id, bookID: bookID, chapterHref: chapterHref,
                engine: engine.rawValue, text: text,
                createdAt: Date(), sourceHash: "stub"
            )
            ctx.insert(row)
            try ctx.save()
        }
        return text
    }
}
