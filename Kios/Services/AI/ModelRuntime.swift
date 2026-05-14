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
