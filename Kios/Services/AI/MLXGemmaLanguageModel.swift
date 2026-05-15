// Kios/Services/AI/MLXGemmaLanguageModel.swift
import Foundation
import os
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

        Output a single JSON value matching exactly this schema:

        \(schema)

        Output format rules — follow ALL of them:
        - Start your reply with `{` (or `[` if the schema's top level is an array).
        - End your reply with the matching `}` or `]`.
        - Do NOT wrap the JSON in markdown code fences. No triple backticks.
        - Do NOT prefix with phrases like "Here is the JSON:" or "Sure!".
        - Do NOT add any prose, explanation, or commentary before or after.
        - The first character of your reply must be `{` or `[`.
        """
        if let first = try? await collectAndDecode(type, system: baseSystem, user: user) {
            return first
        }
        let retrySystem = baseSystem + """


        Your previous reply could not be parsed as JSON. The most common cause \
        is wrapping the JSON in ```json ... ``` markdown fences — do NOT do \
        this. Start your reply directly with `{` or `[`. No backticks, no \
        prose, no preamble, no trailing commentary.
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
        let buffer = OSAllocatedUnfairLock<String>(initialState: "")
        try await runner.generate(prompt: prompt, maxNewTokens: 4096) { token in
            buffer.withLock { $0.append(token) }
        }
        let raw = buffer.withLock { $0 }
        let body = Self.extractJSONBody(raw)
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }

    /// Extracts the first balanced JSON value from a model response. Walks the
    /// string forward from the first `{` or `[`, tracking quote state and
    /// brace depth, until the matching close bracket. Returns the substring
    /// from open to close; returns the input unchanged if no JSON value is
    /// found (caller's decode then surfaces a meaningful diagnostic).
    ///
    /// Gemma 4 has a persistent habit of wrapping JSON responses in markdown
    /// (` ```json {...} ``` `) or framing prose ("Here is the JSON: {...}").
    /// The retry pass in `extract` cannot escape this — both attempts produce
    /// the same shape — so the parser layer must be robust. Handles markdown
    /// fences, leading commentary, trailing commentary, nested structures,
    /// and quoted strings that contain braces or escaped quotes.
    static func extractJSONBody(_ s: String) -> String {
        guard let start = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return s
        }
        let opener = s[start]
        let closer: Character = opener == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                escaped = false
            } else if inString && c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == opener {
                    depth += 1
                } else if c == closer {
                    depth -= 1
                    if depth == 0 {
                        return String(s[start...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        return String(s[start...])
    }
}
