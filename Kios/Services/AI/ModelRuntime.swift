import Foundation

/// Generates tokens from a loaded MLX module. Real implementation lives
/// alongside `MLXGemmaLanguageModel`. This protocol exists so tests can
/// substitute a deterministic runner.
protocol ModelRunner: Sendable {
    func generate(
        prompt: String,
        maxNewTokens: Int,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws
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

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

/// MLX-backed `ModelRunner`. Wraps a loaded `ModelContainer` and streams
/// generated text deltas (already detokenized by MLXLMCommon) via the
/// `onToken` callback. Honors `Task.isCancelled`.
final class MLXModelRunner: ModelRunner {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func generate(
        prompt: String,
        maxNewTokens: Int,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws {
        let parameters = GenerateParameters(maxTokens: maxNewTokens, temperature: 0.4)
        try await container.perform { (context: ModelContext) in
            let userInput = UserInput(prompt: prompt)
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
        let configuration = ModelConfiguration(directory: directory)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        )
        return MLXModelRunner(container: container)
    }
}
#endif
