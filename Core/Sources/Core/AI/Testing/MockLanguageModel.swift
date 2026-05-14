import Foundation

/// In-memory `LanguageModel` for tests. Exposed from Core (not the test target)
/// so the iOS app's test target can use it without duplicating the type.
public final class MockLanguageModel: LanguageModel, @unchecked Sendable {
    public enum Response: Sendable {
        case streamChunks([String], delayPerChunk: Duration)
        case fail(any Error)
        case stallForever
    }

    public enum ExtractResponse: @unchecked Sendable {
        case value(any Codable & Sendable)
        case fail(any Error)
    }

    /// Dynamic interceptor for `extract<T>`. Receives the requested type plus
    /// the prompts. Return a value to use as the response, or `nil` to fall
    /// back to the next queued `ExtractResponse`. `async throws` so test code
    /// can sleep / await inside (used for cancellation tests).
    public typealias ExtractInterceptor = @Sendable (Any.Type, String, String) async throws -> (any Codable & Sendable)?

    public let contextBudgetCharacters: Int
    private let lock = NSLock()
    private var _calls: [(system: String, user: String)] = []
    private var _responseIndex: Int = 0
    private let _responses: [Response]
    private var _extractResponses: [ExtractResponse] = []
    private var _interceptor: ExtractInterceptor?

    public var calls: [(system: String, user: String)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    public init(contextBudgetCharacters: Int = 12_000, responses: [Response] = []) {
        self.contextBudgetCharacters = contextBudgetCharacters
        self._responses = responses
    }

    public func enqueueExtract(_ response: ExtractResponse) {
        lock.lock(); defer { lock.unlock() }
        _extractResponses.append(response)
    }

    public func setExtractInterceptor(_ block: @escaping ExtractInterceptor) {
        lock.lock(); defer { lock.unlock() }
        _interceptor = block
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

    public func extract<T: Decodable & Sendable>(
        _ type: T.Type,
        schema: String,
        system: String,
        user: String
    ) async throws -> T {
        let interceptor: ExtractInterceptor? = {
            lock.lock(); defer { lock.unlock() }
            return _interceptor
        }()

        if let interceptor {
            if let value = try await interceptor(type, system, user) {
                guard let typed = value as? T else {
                    throw ExtractionError.unsupportedType(
                        "interceptor returned \(Swift.type(of: value)), wanted \(T.self)"
                    )
                }
                return typed
            }
            // Interceptor returned nil — fall through to the queue.
        }

        let next: ExtractResponse = try {
            lock.lock(); defer { lock.unlock() }
            guard !_extractResponses.isEmpty else {
                throw ExtractionError.unsupportedType(String(describing: type))
            }
            return _extractResponses.removeFirst()
        }()
        return try unwrap(next, as: T.self)
    }

    private func unwrap<T: Decodable & Sendable>(_ response: ExtractResponse, as: T.Type) throws -> T {
        switch response {
        case .value(let v):
            guard let typed = v as? T else {
                throw ExtractionError.unsupportedType(
                    "enqueued \(Swift.type(of: v)), wanted \(T.self)"
                )
            }
            return typed
        case .fail(let error):
            throw error
        }
    }
}
