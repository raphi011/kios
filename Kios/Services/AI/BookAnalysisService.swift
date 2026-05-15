import Foundation
import SwiftData
import os
import Core

private let analyzeLog = Logger(subsystem: "com.raphi011.kios", category: "analyze")

/// A chapter's reading-order index + resource href + display title. Returned
/// by the `chaptersFor` closure. Sendable for cross-task hop safety.
struct ChapterRef: Sendable, Equatable {
    let index: Int
    let href: String
    let title: String
}

/// Subset of `AISummaryService` used by `BookAnalysisService`. Protocol-shaped
/// so tests can substitute a stub that returns canned chapter summaries
/// without running the language model.
@MainActor
protocol AISummaryServiceHelping: AnyObject {
    func generateChapterSummary(
        bookID: UUID, chapterHref: String, chapterTitle: String,
        engine: AIEngine, model: any LanguageModel
    ) async throws -> String
}

extension AISummaryService: AISummaryServiceHelping {}

/// `@MainActor`, `@Observable`. Owns the in-flight analysis Task for one
/// book; persists progress directly into the shared `modelContext`. View
/// code reads `current` (the row) plus its own SwiftData `@Query` for
/// `CharacterMention` / `CharacterProfile` rows.
@MainActor
@Observable
final class BookAnalysisService {
    private let modelContext: ModelContext
    private let provider: any AILanguageModelProviding
    private let extractor: any AIChapterTextExtracting
    private let summaryHelper: any AISummaryServiceHelping
    /// Closure that returns the chapter list for a given bookID. In production
    /// this resolves the Readium `Publication` and reads its `readingOrder`;
    /// in tests it returns canned `[ChapterRef]`.
    private let chaptersFor: @Sendable (UUID) async throws -> [ChapterRef]

    private var task: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        provider: any AILanguageModelProviding,
        extractor: any AIChapterTextExtracting,
        summaryHelper: any AISummaryServiceHelping,
        chaptersFor: @escaping @Sendable (UUID) async throws -> [ChapterRef]
    ) {
        self.modelContext = modelContext
        self.provider = provider
        self.extractor = extractor
        self.summaryHelper = summaryHelper
        self.chaptersFor = chaptersFor
    }

    /// Creates/refreshes the `BookAnalysis` row and kicks off the pipeline
    /// Task. Returns once the row is persisted; the Task runs to completion
    /// in the background. Caller observes progress through SwiftData.
    func start(bookID: UUID, engine: AIEngine) async throws {
        let existing = try modelContext.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        for row in existing { modelContext.delete(row) }

        let chapters = try await chaptersFor(bookID)
        let row = BookAnalysis(
            bookID: bookID,
            engine: engine.rawValue,
            chaptersTotal: chapters.count
        )
        modelContext.insert(row)
        try modelContext.save()

        let provider = self.provider
        let extractor = self.extractor
        let context = self.modelContext

        let total = chapters.count
        analyzeLog.info("start bookID=\(bookID.uuidString, privacy: .public) engine=\(engine.rawValue, privacy: .public) chapters=\(total)")
        task = Task { [weak self] in
            do {
                let model = try await provider.languageModel(for: engine)
                for chapter in chapters {
                    try Task.checkCancellation()
                    analyzeLog.info("chapter.extract.begin index=\(chapter.index)/\(total) href=\(chapter.href, privacy: .public)")
                    let text = try await extractor.extract(
                        bookID: bookID, chapterHref: chapter.href, cutoff: nil
                    )
                    analyzeLog.info("chapter.extract.text index=\(chapter.index) chars=\(text.count)")
                    let response: ChapterCharactersResponse = try await model.extract(
                        ChapterCharactersResponse.self,
                        schema: CharacterExtractionPrompts.charactersSchema,
                        system: CharacterExtractionPrompts.characterExtractionSystem,
                        user: text
                    )
                    let charCount = response.characters.count
                    analyzeLog.info("chapter.extract.end index=\(chapter.index) characters=\(charCount)")
                    await MainActor.run {
                        for c in response.characters {
                            let mention = CharacterMention(
                                id: UUID(), bookID: bookID,
                                chapterIndex: chapter.index, chapterHref: chapter.href,
                                canonicalName: c.canonicalName,
                                aliasesInChapter: c.aliases,
                                descriptionFromChapter: c.descriptionFromChapter,
                                significance: c.significance,
                                quote: c.quote, profileID: nil
                            )
                            context.insert(mention)
                        }
                        row.chaptersCompleted = chapter.index + 1
                        try? context.save()
                    }
                    // Chapter-summary pass — per chapter, immediately after extraction.
                    // Errors here mark the analysis as failed (consistent with extraction).
                    if let helper = self?.summaryHelper {
                        analyzeLog.info("chapter.summary.begin index=\(chapter.index)")
                        _ = try await helper.generateChapterSummary(
                            bookID: bookID,
                            chapterHref: chapter.href,
                            chapterTitle: chapter.title,
                            engine: engine,
                            model: model
                        )
                        analyzeLog.info("chapter.summary.end index=\(chapter.index)")
                    }
                }
                analyzeLog.info("phase.synthesis.begin bookID=\(bookID.uuidString, privacy: .public)")
                try await self?.runSynthesisPass(bookID: bookID, model: model, row: row)
                analyzeLog.info("phase.bookSummary.begin bookID=\(bookID.uuidString, privacy: .public)")
                try await self?.runBookSummaryPass(bookID: bookID, engine: engine, model: model, row: row)
                analyzeLog.info("done bookID=\(bookID.uuidString, privacy: .public)")
            } catch is CancellationError {
                analyzeLog.info("canceled bookID=\(bookID.uuidString, privacy: .public)")
                await MainActor.run {
                    row.status = "failed"
                    row.failureReason = "Canceled"
                    try? context.save()
                }
            } catch {
                analyzeLog.error("failed bookID=\(bookID.uuidString, privacy: .public) error=\(String(describing: error))")
                await MainActor.run {
                    row.status = "failed"
                    row.failureReason = error.localizedDescription
                    try? context.save()
                }
            }
        }
    }

    /// Test-only sugar: awaits the spawned Task. Production callers don't
    /// await — they let SwiftData propagate state into views.
    #if DEBUG
    func startAndAwait(bookID: UUID, engine: AIEngine) async throws {
        try await start(bookID: bookID, engine: engine)
        await task?.value
    }
    #endif

    private func runSynthesisPass(
        bookID: UUID, model: any LanguageModel, row: BookAnalysis
    ) async throws {
        let serialized: String = try await MainActor.run {
            let mentions = (try? modelContext.fetch(FetchDescriptor<CharacterMention>(
                predicate: #Predicate { $0.bookID == bookID }
            ))) ?? []
            return try serializeMentions(mentions)
        }
        let response: ProfilesSynthesisResponse = try await model.extract(
            ProfilesSynthesisResponse.self,
            schema: CharacterExtractionPrompts.profilesSchema,
            system: CharacterExtractionPrompts.profileSynthesisSystem,
            user: serialized
        )
        await MainActor.run {
            // Re-fetch mentions for the back-link write since we can't carry the
            // @Model instances across the await boundary.
            let mentions = (try? modelContext.fetch(FetchDescriptor<CharacterMention>(
                predicate: #Predicate { $0.bookID == bookID }
            ))) ?? []
            for p in response.profiles {
                let merged = mentions.filter { p.mentionIDs.contains($0.id) }
                let profile = CharacterProfile(
                    id: UUID(), bookID: bookID,
                    canonicalName: p.canonicalName,
                    allAliases: p.allAliases,
                    synthesizedDescription: p.synthesizedDescription,
                    earliestChapterIndex: merged.map(\.chapterIndex).min() ?? 0,
                    latestChapterIndex: merged.map(\.chapterIndex).max() ?? 0
                )
                modelContext.insert(profile)
                for m in merged { m.profileID = profile.id }
            }
            try? modelContext.save()
        }
    }

    /// Concatenates the persisted `ChapterSummary` rows for the book and runs
    /// one final summarization pass; persists the result as a `BookSummary`
    /// row and marks the `BookAnalysis` row "completed". Called as the last
    /// step of the analyze pipeline (after the synthesis pass).
    private func runBookSummaryPass(
        bookID: UUID, engine: AIEngine, model: any LanguageModel, row: BookAnalysis
    ) async throws {
        let concat: String = await MainActor.run {
            let summaries = (try? modelContext.fetch(FetchDescriptor<ChapterSummary>(
                predicate: #Predicate { $0.bookID == bookID }
            )))?.sorted { $0.chapterHref < $1.chapterHref } ?? []
            return summaries.map { "Chapter: \($0.chapterHref)\n\($0.text)" }.joined(separator: "\n\n")
        }
        guard !concat.isEmpty else {
            await MainActor.run {
                row.status = "completed"
                row.completedAt = Date()
                try? modelContext.save()
            }
            return
        }
        let (system, user) = PromptTemplates.bookSummary(body: concat)
        var accumulated = ""
        for try await tok in model.complete(system: system, user: user) {
            try Task.checkCancellation()
            accumulated += tok
        }
        await MainActor.run {
            let existing = (try? modelContext.fetch(FetchDescriptor<BookSummary>(
                predicate: #Predicate { $0.bookID == bookID }
            ))) ?? []
            for r in existing { modelContext.delete(r) }
            let summary = BookSummary(bookID: bookID, engine: engine.rawValue, text: accumulated)
            modelContext.insert(summary)
            row.status = "completed"
            row.completedAt = Date()
            try? modelContext.save()
        }
    }

    private func serializeMentions(_ mentions: [CharacterMention]) throws -> String {
        struct WireMention: Codable {
            let id: UUID
            let canonicalName: String
            let aliases: [String]
            let descriptionFromChapter: String
            let chapterIndex: Int
        }
        let wire = mentions.map {
            WireMention(
                id: $0.id, canonicalName: $0.canonicalName,
                aliases: $0.aliasesInChapter,
                descriptionFromChapter: $0.descriptionFromChapter,
                chapterIndex: $0.chapterIndex
            )
        }
        let data = try JSONEncoder().encode(wire)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Re-runs only chapters that have no `CharacterMention` rows yet; then
    /// always re-runs the synthesis pass. Use when the user taps "Resume"
    /// on a failed analysis.
    func resume(bookID: UUID, engine: AIEngine) async throws {
        let allChapters = try await chaptersFor(bookID)
        let mentions = try modelContext.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        let extractedIndices = Set(mentions.map(\.chapterIndex))
        let rows = try modelContext.fetch(FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        guard let row = rows.first else {
            try await start(bookID: bookID, engine: engine)
            return
        }
        let remaining = allChapters.filter { !extractedIndices.contains($0.index) }
        row.status = "in_progress"
        row.failureReason = nil
        try modelContext.save()

        let provider = self.provider
        let extractor = self.extractor
        let context = self.modelContext

        task = Task { [weak self] in
            do {
                let model = try await provider.languageModel(for: engine)
                for chapter in remaining {
                    try Task.checkCancellation()
                    let text = try await extractor.extract(
                        bookID: bookID, chapterHref: chapter.href, cutoff: nil
                    )
                    let response: ChapterCharactersResponse = try await model.extract(
                        ChapterCharactersResponse.self,
                        schema: CharacterExtractionPrompts.charactersSchema,
                        system: CharacterExtractionPrompts.characterExtractionSystem,
                        user: text
                    )
                    await MainActor.run {
                        for c in response.characters {
                            context.insert(CharacterMention(
                                id: UUID(), bookID: bookID,
                                chapterIndex: chapter.index, chapterHref: chapter.href,
                                canonicalName: c.canonicalName,
                                aliasesInChapter: c.aliases,
                                descriptionFromChapter: c.descriptionFromChapter,
                                significance: c.significance,
                                quote: c.quote, profileID: nil
                            ))
                        }
                        row.chaptersCompleted = max(row.chaptersCompleted, chapter.index + 1)
                        try? context.save()
                    }
                    if let helper = self?.summaryHelper {
                        _ = try await helper.generateChapterSummary(
                            bookID: bookID,
                            chapterHref: chapter.href,
                            chapterTitle: chapter.title,
                            engine: engine,
                            model: model
                        )
                    }
                }
                try await self?.runSynthesisPass(bookID: bookID, model: model, row: row)
                try await self?.runBookSummaryPass(bookID: bookID, engine: engine, model: model, row: row)
            } catch is CancellationError {
                await MainActor.run {
                    row.status = "failed"
                    row.failureReason = "Canceled"
                    try? context.save()
                }
            } catch {
                await MainActor.run {
                    row.status = "failed"
                    row.failureReason = error.localizedDescription
                    try? context.save()
                }
            }
        }
    }

    /// Wipes all prior analysis state for the book and runs from scratch.
    func restart(bookID: UUID, engine: AIEngine) async throws {
        let mentions = try modelContext.fetch(FetchDescriptor<CharacterMention>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        for m in mentions { modelContext.delete(m) }
        let profiles = try modelContext.fetch(FetchDescriptor<CharacterProfile>(
            predicate: #Predicate { $0.bookID == bookID }
        ))
        for p in profiles { modelContext.delete(p) }
        try modelContext.save()
        try await start(bookID: bookID, engine: engine)
    }

    #if DEBUG
    func resumeAndAwait(bookID: UUID, engine: AIEngine) async throws {
        try await resume(bookID: bookID, engine: engine)
        await task?.value
    }
    func taskValue() async {
        await task?.value
    }
    #endif

    /// Cancels the in-flight pipeline. The task reference is retained so
    /// callers can `await taskValue()` after cancel to observe terminal
    /// state. The catch-block on the task body marks the row "failed" with
    /// `failureReason = "Canceled"` once cancellation propagates.
    func cancel() {
        task?.cancel()
    }
}
