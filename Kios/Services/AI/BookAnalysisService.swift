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
        // Pipeline Task spawn comes in Task 13.
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
