import Foundation

/// In-memory `LanguageModel` for tests. Exposed from Core (not the test target)
/// so the iOS app's test target can use it without duplicating the type.
public final class MockLanguageModel: LanguageModel, @unchecked Sendable {
    public enum Response: Sendable {
        case streamChunks([String], delayPerChunk: Duration)
        case fail(any Error)
        case stallForever
    }

    public let contextBudgetCharacters: Int
    private let lock = NSLock()
    private var _calls: [(system: String, user: String)] = []
    private var _responseIndex: Int = 0
    private let _responses: [Response]

    public var calls: [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public init(contextBudgetCharacters: Int = 12_000, responses: [Response]) {
        self.contextBudgetCharacters = contextBudgetCharacters
        self._responses = responses
    }

    public func complete(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        let response: Response = {
            lock.lock(); defer { lock.unlock() }
            _calls.append((system, user))
            let idx = min(_responseIndex, _responses.count - 1)
            _responseIndex += 1
            return _responses[idx]
        }()

        return AsyncThrowingStream { continuation in
            let task = Task {
                switch response {
                case .streamChunks(let chunks, let delay):
                    for chunk in chunks {
                        if Task.isCancelled { continuation.finish(); return }
                        try? await Task.sleep(for: delay)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                case .fail(let error):
                    continuation.finish(throwing: error)
                case .stallForever:
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
