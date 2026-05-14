import Testing
@testable import Kios
import Foundation

@Suite("ModelRuntime")
struct ModelRuntimeTests {
    private final class StubRunner: ModelRunner {
        let id = UUID()
        func generate(prompt: AIChatPrompt, maxNewTokens: Int, onToken: @Sendable @escaping (String) -> Void) async throws {
            onToken("ok")
        }
    }

    private final class StubLoader: RunnerLoading, @unchecked Sendable {
        private let lock = NSLock()
        private var _loadCount = 0
        var loadCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _loadCount
        }
        func load(from directory: URL) async throws -> any ModelRunner {
            lock.lock(); _loadCount += 1; lock.unlock()
            return StubRunner()
        }
    }

    @Test("first acquire loads, second acquire reuses")
    func reuse() async throws {
        let loader = StubLoader()
        let rt = ModelRuntime(loader: loader, idleTimeout: .seconds(60))
        let dir = URL(fileURLWithPath: "/tmp/stub")
        _ = try await rt.acquire(at: dir)
        _ = try await rt.acquire(at: dir)
        #expect(loader.loadCount == 1)
    }

    @Test("release evicts; subsequent acquire reloads")
    func releaseReload() async throws {
        let loader = StubLoader()
        let rt = ModelRuntime(loader: loader, idleTimeout: .seconds(60))
        let dir = URL(fileURLWithPath: "/tmp/stub")
        _ = try await rt.acquire(at: dir)
        await rt.release()
        _ = try await rt.acquire(at: dir)
        #expect(loader.loadCount == 2)
    }

    @Test("idle timeout evicts the runner")
    func idleEviction() async throws {
        let loader = StubLoader()
        let rt = ModelRuntime(loader: loader, idleTimeout: .milliseconds(100))
        let dir = URL(fileURLWithPath: "/tmp/stub")
        _ = try await rt.acquire(at: dir)
        try await Task.sleep(for: .milliseconds(200))
        await rt.evictIfIdle()
        _ = try await rt.acquire(at: dir)
        #expect(loader.loadCount == 2)
    }
}
