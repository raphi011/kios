import Foundation
import SwiftData
import Core
import CryptoKit

protocol AILanguageModelProviding: Sendable {
    func languageModel(for engine: AIEngine) async throws -> any LanguageModel
}

protocol AIChapterTextExtracting: Sendable {
    func extract(bookID: UUID, chapterHref: String, cutoff: Double?) async throws -> String
}

/// Two roles bundled into one class:
///   • `askAboutSelection` — drives the in-reader Ask-AI sheet, streaming
///     answers into `questionState` for the bound view.
///   • `generateChapterSummary` — non-streaming helper used by
///     `BookAnalysisService` to produce (or return cached) per-chapter
///     summaries during the analyze pipeline. Cancellation is via
///     cooperative `Task.checkCancellation()` in the calling pipeline; this
///     method itself is single-shot.
@MainActor
@Observable
final class AISummaryService {
    enum State {
        case idle
        case streaming(String)
        case done(String)
        case failed(any Error)
    }

    private(set) var questionState: State = .idle

    private let modelContext: ModelContext
    private let modelProvider: any AILanguageModelProviding
    private let textExtractor: any AIChapterTextExtracting
    private var questionTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        modelProvider: any AILanguageModelProviding,
        textExtractor: any AIChapterTextExtracting
    ) {
        self.modelContext = modelContext
        self.modelProvider = modelProvider
        self.textExtractor = textExtractor
    }

    func askAboutSelection(
        selection: String,
        question: String,
        bookID: UUID,
        bookTitle: String,
        chapterTitle: String?,
        engine: AIEngine
    ) async {
        questionTask?.cancel()
        questionState = .idle

        let model: any LanguageModel
        do {
            model = try await modelProvider.languageModel(for: engine)
        } catch {
            questionState = .failed(error)
            return
        }

        let (system, user) = PromptTemplates.selectionQuestion(
            selection: selection, question: question,
            bookTitle: bookTitle, chapterTitle: chapterTitle
        )

        let task = Task { @MainActor in
            do {
                var accumulated = ""
                for try await tok in model.complete(system: system, user: user) {
                    try Task.checkCancellation()
                    accumulated += tok
                    questionState = .streaming(accumulated)
                }
                questionState = .done(accumulated)
            } catch is CancellationError {
                questionState = .idle
            } catch {
                questionState = .failed(error)
            }
        }
        questionTask = task
        await task.value
    }

    func cancel() {
        questionTask?.cancel()
    }

    /// Produces (or refreshes) the cached `ChapterSummary` for one chapter
    /// without surfacing any streaming state. Used by the book-analysis
    /// pipeline (which has its own progress UI). Returns the persisted text.
    /// If a current-content-hash `ChapterSummary` already exists for
    /// `(bookID, chapterHref, engine)`, returns its text without re-running
    /// the model.
    @MainActor
    func generateChapterSummary(
        bookID: UUID,
        chapterHref: String,
        chapterTitle: String,
        engine: AIEngine,
        model: any LanguageModel
    ) async throws -> String {
        let body = try await textExtractor.extract(bookID: bookID, chapterHref: chapterHref, cutoff: nil)
        let hash = Self.sha256Hex(of: Data(body.utf8))
        let id = ChapterSummary.makeID(bookID: bookID, chapterHref: chapterHref, engine: engine)

        var descriptor = FetchDescriptor<ChapterSummary>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            if existing.sourceHash == hash {
                return existing.text
            } else {
                modelContext.delete(existing)
            }
        }

        var accumulated = ""
        if body.count <= model.contextBudgetCharacters {
            let (system, user) = PromptTemplates.chapterSummary(
                chapterTitle: chapterTitle, bookTitle: "", body: body
            )
            for try await tok in model.complete(system: system, user: user) {
                try Task.checkCancellation()
                accumulated += tok
            }
        } else {
            let summarizer = MapReduceSummarizer(
                model: model,
                chunker: TextChunker(budgetCharacters: model.contextBudgetCharacters)
            )
            let stream = summarizer.summarize(
                body: body,
                chapterTitle: chapterTitle,
                onProgress: { _, _ in }
            )
            for try await tok in stream {
                try Task.checkCancellation()
                accumulated += tok
            }
        }
        let row = ChapterSummary(
            id: id, bookID: bookID, chapterHref: chapterHref,
            engine: engine.rawValue,
            text: accumulated, createdAt: Date(), sourceHash: hash
        )
        modelContext.insert(row)
        try modelContext.save()
        return accumulated
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
