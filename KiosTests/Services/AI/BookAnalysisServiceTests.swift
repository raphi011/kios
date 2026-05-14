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

        let mock = MockLanguageModel()
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
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1"),
                ChapterRef(index: 1, href: "ch2"),
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
        final class CallCounter: @unchecked Sendable {
            let lock = NSLock()
            var n = 0
        }
        let counter = CallCounter()
        mock.setExtractInterceptor { _, _, _ in
            counter.lock.lock()
            counter.n += 1
            let call = counter.n
            counter.lock.unlock()
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
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1"),
                ChapterRef(index: 1, href: "ch2"),
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

        let mock = MockLanguageModel()
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
            chaptersFor: { _ in [
                ChapterRef(index: 0, href: "ch1"),
                ChapterRef(index: 1, href: "ch2"),
                ChapterRef(index: 2, href: "ch3"),
            ] }
        )
        try await service.resumeAndAwait(bookID: bookID, engine: .gemma4_e4b)

        let mentions = try ctx.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        #expect(Set(mentions.map(\.canonicalName)) == Set(["Alice", "Bob", "Carol"]))
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
