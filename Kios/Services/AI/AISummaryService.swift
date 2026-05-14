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

@MainActor
@Observable
final class AISummaryService {
    enum State {
        case idle
        case streaming(String)
        case done(String)
        case failed(any Error)
    }

    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    private(set) var summaryState: State = .idle
    private(set) var questionState: State = .idle
    private(set) var progress: Progress?

    private let modelContext: ModelContext
    private let modelProvider: any AILanguageModelProviding
    private let textExtractor: any AIChapterTextExtracting
    private var summaryTask: Task<Void, Never>?
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

    func summarizeCurrentChapter(
        bookID: UUID,
        chapterHref: String,
        chapterTitle: String,
        cutoff: Double?,
        scope: SummaryScope,
        engine: AIEngine
    ) async {
        summaryTask?.cancel()
        summaryState = .idle
        progress = nil

        let body: String
        do {
            body = try await textExtractor.extract(bookID: bookID, chapterHref: chapterHref, cutoff: cutoff)
        } catch {
            summaryState = .failed(error)
            return
        }
        let hash = Self.sha256Hex(of: Data(body.utf8))
        let id = ChapterSummary.makeID(bookID: bookID, chapterHref: chapterHref, scope: scope, engine: engine)

        var descriptor = FetchDescriptor<ChapterSummary>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            if existing.sourceHash == hash {
                summaryState = .done(existing.text)
                return
            } else {
                modelContext.delete(existing)
                try? modelContext.save()
            }
        }

        let model: any LanguageModel
        do {
            model = try await modelProvider.languageModel(for: engine)
        } catch {
            summaryState = .failed(error)
            return
        }

        let task = Task { @MainActor in
            do {
                var accumulated = ""
                if body.count <= model.contextBudgetCharacters {
                    let (system, user) = PromptTemplates.chapterSummary(
                        chapterTitle: chapterTitle, bookTitle: "", body: body, scope: scope
                    )
                    for try await tok in model.complete(system: system, user: user) {
                        try Task.checkCancellation()
                        accumulated += tok
                        summaryState = .streaming(accumulated)
                    }
                } else {
                    let summarizer = MapReduceSummarizer(
                        model: model,
                        chunker: TextChunker(budgetCharacters: model.contextBudgetCharacters)
                    )
                    for try await tok in summarizer.summarize(
                        body: body, chapterTitle: chapterTitle
                    ) { done, total in
                        Task { @MainActor [weak self] in
                            self?.progress = Progress(done: done, total: total)
                        }
                    } {
                        try Task.checkCancellation()
                        accumulated += tok
                        summaryState = .streaming(accumulated)
                    }
                }
                let row = ChapterSummary(
                    id: id, bookID: bookID, chapterHref: chapterHref,
                    scope: scope.rawValue, engine: engine.rawValue,
                    text: accumulated, createdAt: Date(), sourceHash: hash
                )
                modelContext.insert(row)
                try modelContext.save()
                summaryState = .done(accumulated)
                progress = nil
            } catch is CancellationError {
                summaryState = .idle
            } catch {
                summaryState = .failed(error)
            }
        }
        summaryTask = task
        await task.value
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
        summaryTask?.cancel()
        questionTask?.cancel()
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
