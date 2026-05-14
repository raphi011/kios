import Foundation

public struct MapReduceSummarizer: Sendable {
    public let model: any LanguageModel
    public let chunker: TextChunker

    public init(model: any LanguageModel, chunker: TextChunker) {
        self.model = model
        self.chunker = chunker
    }

    public func summarize(
        body: String,
        chapterTitle: String,
        onProgress: @Sendable @escaping (_ done: Int, _ total: Int) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = chunker.chunks(of: body)
                    onProgress(0, chunks.count)

                    if chunks.count <= 1 {
                        let (system, user) = PromptTemplates.chapterSummary(
                            chapterTitle: chapterTitle,
                            bookTitle: "",
                            body: body
                        )
                        for try await partial in model.complete(system: system, user: user) {
                            try Task.checkCancellation()
                            continuation.yield(partial)
                        }
                        onProgress(1, 1)
                        continuation.finish()
                        return
                    }

                    var partials: [String] = []
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        let (system, user) = PromptTemplates.mapStep(chunk: chunk, chapterTitle: chapterTitle)
                        var partial = ""
                        for try await tok in model.complete(system: system, user: user) {
                            try Task.checkCancellation()
                            partial += tok
                        }
                        partials.append(partial)
                        onProgress(index + 1, chunks.count + 1)
                    }

                    try Task.checkCancellation()
                    let (system, user) = PromptTemplates.reduceStep(partials: partials, chapterTitle: chapterTitle)
                    for try await tok in model.complete(system: system, user: user) {
                        try Task.checkCancellation()
                        continuation.yield(tok)
                    }
                    onProgress(chunks.count + 1, chunks.count + 1)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
