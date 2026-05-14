import Foundation
import os

/// Generates tokens from a loaded MLX module. Real implementation lives
/// alongside `MLXGemmaLanguageModel`. This protocol exists so tests can
/// substitute a deterministic runner.
protocol ModelRunner: Sendable {
    func generate(
        prompt: AIChatPrompt,
        maxNewTokens: Int,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws
}

/// System + user pair handed to the runner. The MLX path forwards this as a
/// structured `UserInput.Chat` so the model's bundled jinja template applies
/// automatically — required for Gemma 4, whose template (`<|turn>role`/
/// `<turn|>` markers) is incompatible with the Gemma 3 string format we
/// previously hand-rolled.
struct AIChatPrompt: Sendable, Equatable {
    let system: String
    let user: String
}

/// Loads a runner from a directory on disk. Real implementation calls
/// MLXLLM; tests substitute an in-memory loader.
protocol RunnerLoading: Sendable {
    func load(from directory: URL) async throws -> any ModelRunner
}

actor ModelRuntime {
    private enum State {
        case unloaded
        case ready(runner: any ModelRunner, lastUsed: Date, directory: URL)
    }

    private let loader: any RunnerLoading
    private let idleTimeout: Duration
    private var state: State = .unloaded

    init(loader: any RunnerLoading, idleTimeout: Duration = .seconds(300)) {
        self.loader = loader
        self.idleTimeout = idleTimeout
    }

    func acquire(at directory: URL) async throws -> any ModelRunner {
        if case .ready(let runner, _, let dir) = state, dir == directory {
            state = .ready(runner: runner, lastUsed: Date(), directory: dir)
            return runner
        }
        let runner = try await loader.load(from: directory)
        state = .ready(runner: runner, lastUsed: Date(), directory: directory)
        return runner
    }

    func release() {
        state = .unloaded
    }

    func evictIfIdle() {
        guard case .ready(_, let lastUsed, _) = state else { return }
        let elapsed = Date().timeIntervalSince(lastUsed)
        let timeoutSeconds = Double(idleTimeout.components.seconds) +
                             Double(idleTimeout.components.attoseconds) / 1e18
        if elapsed >= timeoutSeconds {
            state = .unloaded
        }
    }
}

/// Stub loader used when MLXLLM is unavailable at compile time (e.g. SwiftPM
/// resolution skipped on this platform). Acquiring throws so callers surface
/// "Gemma unavailable" rather than crashing on a missing runner.
struct UnavailableRunnerLoader: RunnerLoading {
    enum LoadError: LocalizedError {
        case mlxNotAvailable
        var errorDescription: String? { "MLX runtime is not available in this build." }
    }
    func load(from directory: URL) async throws -> any ModelRunner {
        throw LoadError.mlxNotAvailable
    }
}

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// MLX-backed `ModelRunner`. Wraps a loaded `ModelContainer` and streams
/// generated text deltas (already detokenized by MLXLMCommon) via the
/// `onToken` callback. Honors `Task.isCancelled`.
final class MLXModelRunner: ModelRunner {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func generate(
        prompt: AIChatPrompt,
        maxNewTokens: Int,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        // Do NOT set `kvBits` here. KV-cache quantization in mlx-swift-lm
        // 3.31.3 is opt-in per-model: only Gemma4Attention (and most other
        // attention impls in MLXLLM/Models) call the generic
        // `cache.update(keys:values:)`, which on `QuantizedKVCache` is a
        // hard `fatalError("Use updateQuantized instead")`. Setting `kvBits`
        // here crashes during the first prefill step inside
        // `Gemma4Attention.callAsFunction` → `QuantizedKVCache.update`.
        // Only `GPTOSS` and `MiMoV2Flash` take the `updateQuantized` path.
        //
        // fp16 KV cache is fine for Gemma 4 anyway: the hybrid attention
        // (36 sliding-window layers with a 512-token window + 6 global
        // attention layers) keeps the cache around 1.6 GB even at the full
        // 32 K-token prompt — well below the per-process cap on 8 GB
        // devices with the `increased-memory-limit` entitlement.
        let parameters = GenerateParameters(
            maxTokens: maxNewTokens,
            temperature: 0.4
        )
        try await container.perform { (context: ModelContext) in
            let chat: [Chat.Message] = prompt.system.isEmpty
                ? [.user(prompt.user)]
                : [.system(prompt.system), .user(prompt.user)]
            let userInput = UserInput(chat: chat)
            let lmInput = try await context.processor.prepare(input: userInput)
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            for await generation in stream {
                if Task.isCancelled { break }
                switch generation {
                case .chunk(let delta):
                    onToken(delta)
                case .info:
                    continue
                case .toolCall:
                    continue
                }
            }
        }
    }
}

/// Loads an MLX `ModelContainer` from a local on-disk directory containing
/// the converted MLX weights + tokenizer + config.json.
struct MLXRunnerLoader: RunnerLoading {
    func load(from directory: URL) async throws -> any ModelRunner {
        // Configure MLX's Metal allocator BEFORE the first allocation. iOS
        // jetsam-kills processes that hold "wired" GPU memory past the per-
        // process cap — without these limits MLX will happily allocate until
        // the kernel pushes back, which on iOS means SIGKILL with no .ips
        // crash report.
        //
        // `cacheLimit` caps the buffer cache the allocator holds across
        // allocations. 32 MB is conservative; LLMEval uses 20 MB for smaller
        // models. Wrong values just trade throughput for headroom, never
        // correctness.
        //
        // `memoryLimit` is a soft ceiling on overall MLX allocations. We size
        // it from `os_proc_available_memory()` so it tracks the device's
        // actual budget (which depends on the `increased-memory-limit`
        // entitlement and other apps' pressure), with a ~70 % safety margin
        // so the rest of the reader (Readium, SwiftData) still has room.
        let available = Int(os_proc_available_memory())
        let safetyFloor = 1_500_000_000   // 1.5 GB — never go below
        let memoryLimit = max(safetyFloor, Int(Double(available) * 0.7))
        MLX.Memory.cacheLimit = 32 * 1024 * 1024
        MLX.Memory.memoryLimit = memoryLimit

        // Build a ResolvedModelConfiguration manually so we can set
        // `extraEOSTokens`. The shorter `loadContainer(from:using:)` overload
        // uses `ResolvedModelConfiguration.init(directory:)` which leaves
        // extra EOS empty — and Gemma 4 emits `<turn|>` to end its assistant
        // turn (the chat template's per-turn closing marker, not the
        // tokenizer's primary `<eos>`). Without flagging it here, the runner
        // streams the literal `<turn|>` as text at the end of every reply.
        let resolved = ResolvedModelConfiguration(
            modelDirectory: directory,
            tokenizerDirectory: directory,
            name: directory.lastPathComponent,
            defaultPrompt: "",
            extraEOSTokens: ["<turn|>"],
            eosTokenIds: [],
            toolCallFormat: nil
        )
        let context = try await LLMModelFactory.shared._load(
            configuration: resolved,
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let container = ModelContainer(context: context)
        return MLXModelRunner(container: container)
    }
}
#endif
