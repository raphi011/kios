// Kios/Services/AI/MLXGemmaLanguageModel.swift
import Foundation
import Core

/// `LanguageModel` adapter that drives a `ModelRunner` (typically the
/// MLX-backed `MLXModelRunner`) using the Gemma instruct chat template.
/// Yields token deltas — consumers can simply append.
final class MLXGemmaLanguageModel: LanguageModel {
    let contextBudgetCharacters = 96_000

    private let runner: any ModelRunner

    init(runner: any ModelRunner) {
        self.runner = runner
    }

    func complete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [runner] in
                do {
                    let prompt = GemmaChatTemplate.render(system: system, user: user)
                    try await runner.generate(prompt: prompt, maxNewTokens: 1024) { token in
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
