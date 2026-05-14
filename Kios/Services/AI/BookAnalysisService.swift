import Foundation
import SwiftData
import Core

/// A chapter's reading-order index + resource href. Returned by the
/// `chaptersFor` closure. Sendable for cross-task hop safety.
struct ChapterRef: Sendable, Equatable {
    let index: Int
    let href: String
}

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
    /// Closure that returns the chapter list for a given bookID. In production
    /// this resolves the Readium `Publication` and reads its `readingOrder`;
    /// in tests it returns canned `[ChapterRef]`.
    private let chaptersFor: @Sendable (UUID) async throws -> [ChapterRef]

    private var task: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        provider: any AILanguageModelProviding,
        extractor: any AIChapterTextExtracting,
        chaptersFor: @escaping @Sendable (UUID) async throws -> [ChapterRef]
    ) {
        self.modelContext = modelContext
        self.provider = provider
        self.extractor = extractor
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

        task = Task { [weak self] in
            do {
                let model = try await provider.languageModel(for: engine)
                for chapter in chapters {
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
                }
                try await self?.runSynthesisPass(bookID: bookID, model: model, row: row)
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
        // Real impl in Task 14.
        await MainActor.run {
            row.status = "completed"
            row.completedAt = Date()
            try? modelContext.save()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
