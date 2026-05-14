// Kios/Services/AI/MLXGemmaLanguageModel.swift
import Foundation
import Core

/// `LanguageModel` adapter that drives a `ModelRunner` (typically the
/// MLX-backed `MLXModelRunner`) using a structured chat input so the model's
/// bundled jinja chat template is applied by MLXLMCommon's processor — Gemma 4
/// uses a different turn-marker format (`<|turn>role` / `<turn|>`) than
/// Gemma 3 (`<start_of_turn>` / `<end_of_turn>`) and the runtime is the only
/// place that knows the model's tokens authoritatively.
final class MLXGemmaLanguageModel: LanguageModel {
    /// Practical upper bound on prompt size for on-device Gemma 4 inference.
    /// The model's *stated* window is 128 K tokens; the limiting factor on a
    /// phone is the KV cache. With `kvBits: 4` quantization (configured in
    /// `MLXModelRunner.generate`) the cache footprint is roughly 4× smaller
    /// than fp16, so 32 K tokens (~96 K characters) is comfortably below the
    /// jetsam threshold even on 8 GB devices. Chapters beyond this still go
    /// through `MapReduceSummarizer`.
    let contextBudgetCharacters = 96_000

    private let runner: any ModelRunner

    init(runner: any ModelRunner) {
        self.runner = runner
    }

    func complete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [runner] in
                do {
                    let prompt = AIChatPrompt(system: system, user: user)
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
