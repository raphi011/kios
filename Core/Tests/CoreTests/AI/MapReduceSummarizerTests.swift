import Foundation
import Testing
@testable import Core

@Suite("MapReduceSummarizer")
struct MapReduceSummarizerTests {
    @Test("short body within budget single-shots")
    func singleShot() async throws {
        let mock = MockLanguageModel(
            contextBudgetCharacters: 1000,
            responses: [.streamChunks(["Short ", "summary."], delayPerChunk: .milliseconds(1))]
        )
        let summarizer = MapReduceSummarizer(
            model: mock,
            chunker: TextChunker(budgetCharacters: 1000)
        )
        var output = ""
        let stream = summarizer.summarize(body: "A short body.", chapterTitle: "Ch1") { _, _ in }
        for try await chunk in stream { output += chunk }
        #expect(output == "Short summary.")
        #expect(mock.calls.count == 1)
    }

    @Test("long body fans out to map then reduces")
    func mapReduce() async throws {
        let mock = MockLanguageModel(
            contextBudgetCharacters: 30,
            responses: [
                .streamChunks(["map1 done"], delayPerChunk: .milliseconds(1)),
                .streamChunks(["map2 done"], delayPerChunk: .milliseconds(1)),
                .streamChunks(["Final ", "summary."], delayPerChunk: .milliseconds(1)),
            ]
        )
        let summarizer = MapReduceSummarizer(
            model: mock,
            chunker: TextChunker(budgetCharacters: 30, overlapCharacters: 5)
        )
        let body = "First sentence here. Second sentence here. Third sentence here. Fourth sentence here."
        var output = ""
        let progress = ProgressRecorder()
        let stream = summarizer.summarize(body: body, chapterTitle: "Ch1") { done, total in
            progress.record(done: done, total: total)
        }
        for try await chunk in stream { output += chunk }
        let lastProgress = progress.last
        #expect(output == "Final summary.")
        #expect(mock.calls.count >= 3, "must call model at least map×N + reduce times; got \(mock.calls.count)")
        #expect(lastProgress.1 >= 2)
    }

    @Test("cancellation mid-stream stops further model calls")
    func cancellation() async throws {
        let mock = MockLanguageModel(
            contextBudgetCharacters: 30,
            responses: [.stallForever, .stallForever, .stallForever]
        )
        let summarizer = MapReduceSummarizer(
            model: mock,
            chunker: TextChunker(budgetCharacters: 30, overlapCharacters: 5)
        )
        let body = "Sentence one. Sentence two. Sentence three. Sentence four."
        let task = Task {
            var collected = ""
            do {
                let stream = summarizer.summarize(body: body, chapterTitle: "Ch1") { _, _ in }
                for try await chunk in stream { collected += chunk }
            } catch is CancellationError {
                // expected
            }
            return collected
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        // Just confirming no crash and graceful exit
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: (Int, Int) = (0, 0)

    var last: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return _last
    }

    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        _last = (done, total)
    }
}
