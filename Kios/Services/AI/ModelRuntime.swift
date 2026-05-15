import Foundation
import os

private let mlxLog = Logger(subsystem: "com.raphi011.kios", category: "mlx")

/// Resident memory footprint of this process in MB. Reads
/// `phys_footprint` — the same value iOS uses for jetsam decisions and the
/// one Metal/IOGPU allocations count against on-device. Used by the MLX
/// runner's entry/exit logs so a sysdiagnose around a crash shows how
/// inference allocations track across chapters.
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kerr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576.0
}

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
        let promptChars = prompt.system.count + prompt.user.count
        let startFootprint = physFootprintMB()
        let startTime = Date()
        mlxLog.info("generate.begin promptChars=\(promptChars) maxNewTokens=\(maxNewTokens) footprintMB=\(startFootprint, format: .fixed(precision: 1))")
        let tokenCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        do {
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
                        tokenCount.withLock { $0 += 1 }
                        onToken(delta)
                    case .info:
                        continue
                    case .toolCall:
                        continue
                    }
                }
            }
            let endFootprint = physFootprintMB()
            let elapsedMS = Int(Date().timeIntervalSince(startTime) * 1000)
            let total = tokenCount.withLock { $0 }
            mlxLog.info("generate.end tokens=\(total) elapsedMS=\(elapsedMS) footprintMB=\(endFootprint, format: .fixed(precision: 1)) deltaMB=\(endFootprint - startFootprint, format: .fixed(precision: 1))")
        } catch {
            let endFootprint = physFootprintMB()
            let elapsedMS = Int(Date().timeIntervalSince(startTime) * 1000)
            mlxLog.error("generate.fail error=\(String(describing: error)) elapsedMS=\(elapsedMS) footprintMB=\(endFootprint, format: .fixed(precision: 1))")
            throw error
        }
    }
}

/// Loads an MLX `ModelContainer` from a local on-disk directory containing
/// the converted MLX weights + tokenizer + config.json.
struct MLXRunnerLoader: RunnerLoading {
    func load(from directory: URL) async throws -> any ModelRunner {
        // Cap the Metal buffer cache before the first MLX allocation. iOS
        // counts MLX's "wired" GPU memory against the per-process limit, and
        // the default behavior is unbounded cache growth across allocations.
        // 32 MB mirrors what LLMEval ships (it uses 20 MB for smaller models).
        // Wrong values just trade throughput for headroom, never correctness.
        //
        // NOT setting `MLX.Memory.memoryLimit`: it's a *hard* ceiling on MLX
        // allocations. Picking a value too low stalls or fails inference
        // during legitimate spikes (prefill, kernel JIT); picking it too high
        // is no better than the OS jetsam catching us anyway. Without
        // observed evidence that we need this, we leave it unset and rely on
        // (a) the `increased-memory-limit` entitlement to lift the per-
        // process cap, (b) the `release()` on memory warning / background
        // hooks, and (c) `cacheLimit` above to bound the steady-state.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024

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
