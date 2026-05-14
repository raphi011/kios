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
    /// phone is the KV cache. KV-cache quantization (`kvBits`) is NOT usable
    /// here — `Gemma4Attention` in mlx-swift-lm 3.31.3 calls the generic
    /// `cache.update(...)` which `fatalError`s on `QuantizedKVCache`. With
    /// fp16 cache, Gemma 4's hybrid attention (36 sliding-window layers +
    /// 6 global) keeps the footprint at ~1.6 GB for 32 K-token prompts, so
    /// 96 K characters is a safe budget on 8 GB+ devices. Chapters beyond
    /// this still go through `MapReduceSummarizer`.
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

    func extract<T: Decodable & Sendable>(
        _ type: T.Type,
        schema: String,
        system: String,
        user: String
    ) async throws -> T {
        let baseSystem = """
        \(system)

        Respond with ONLY valid JSON matching this exact shape, no prose \
        before or after:

        \(schema)
        """
        if let first = try? await collectAndDecode(type, system: baseSystem, user: user) {
            return first
        }
        let retrySystem = baseSystem + """

        Your last reply could not be parsed as JSON. Reply with valid JSON \
        matching the shape above. Do NOT include any other text.
        """
        do {
            return try await collectAndDecode(type, system: retrySystem, user: user)
        } catch {
            throw ExtractionError.malformedOutput(
                attempts: 2,
                underlying: String(describing: error)
            )
        }
    }

    private func collectAndDecode<T: Decodable>(
        _ type: T.Type, system: String, user: String
    ) async throws -> T {
        let prompt = AIChatPrompt(system: system, user: user)
        let buffer = TokenBuffer()
        try await runner.generate(prompt: prompt, maxNewTokens: 4096) { token in
            buffer.append(token)
        }
        let text = buffer.text
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

/// Thread-safe string accumulator for the @Sendable onToken closure
/// in `runner.generate`. Local `var` capture is forbidden inside a
/// @Sendable closure.
private final class TokenBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        _text.append(s)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return _text
    }
}
