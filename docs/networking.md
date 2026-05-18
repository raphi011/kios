# Networking best practices

Reference for HTTP networking in this codebase. The shared client is `Core/Sources/Core/HTTPClient.swift`, the test seam is `Core/Sources/Core/MockURLProtocol.swift`. Strict-concurrency clean.

## Foundational types

All networking goes through `URLSession`. There's no third-party HTTP library here — and there shouldn't be. URLSession does everything this app needs.

```swift
// Core/Sources/Core/HTTPClient.swift
public struct HTTPClient: Sendable {
    private let session: URLSession
    private let credentials: BasicCredentials?

    public init(session: URLSession = .shared, credentials: BasicCredentials? = nil) {
        self.session = session
        self.credentials = credentials
    }

    @discardableResult
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let credentials {
            req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.malformedResponse }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401:       throw HTTPError.unauthorized
            case 404:       throw HTTPError.notFound
            default:        throw HTTPError.server(status: http.statusCode, body: data)
            }
        } catch let urlError as URLError {
            throw HTTPError.transport(urlError)
        }
    }
}
```

Worth noting:

- `struct HTTPClient: Sendable` — value-typed and trivially `Sendable`.
- One method, one happy path, one error model.
- Maps `URLError` → `HTTPError.transport(...)` so callers handle a single error type.

## async/await over completion handlers

Always prefer the async API.

```swift
// ✅
let (data, response) = try await URLSession.shared.data(for: request)

// ❌ avoid in new code
URLSession.shared.dataTask(with: request) { ... }.resume()
```

The async API supports cancellation via structured concurrency. The completion-handler API needs manual `URLSessionDataTask.cancel()` bookkeeping.

## URLSession configuration

`URLSession.shared` is fine for one-off reads. For anything stateful (custom timeouts, custom protocols for testing, custom credential handling), create a configured session:

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 30
config.timeoutIntervalForResource = 300
config.waitsForConnectivity = true
config.httpMaximumConnectionsPerHost = 4
let session = URLSession(configuration: config)
```

`URLSessionConfiguration.ephemeral` is `.default` minus the disk cache + cookies — used in this codebase for mock sessions (see below).

## Authentication

### Basic auth

Compute the header yourself; URLSession's challenge mechanism is overkill for a value passed on every request.

```swift
// Core/Sources/Core/HTTPClient.swift
public struct BasicCredentials: Sendable, Equatable {
    public let username: String
    public let password: String

    public var authorizationHeader: String {
        let raw = "\(username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }
}
```

The client attaches it on every request:

```swift
req.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
```

### Bearer tokens

Same pattern — attach `Authorization: Bearer <token>` per request. Store the token in Keychain, not UserDefaults. See `Core/Sources/Core/KeychainStore.swift`.

### URLSessionDelegate (server trust, client certs)

If you need to handle server trust evaluation, client certs, or NTLM, use a delegate:

```swift
final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // evaluate, then:
        completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
    }
}
```

This codebase doesn't need it yet — every server uses plain HTTPS + Basic auth.

## Testing with `URLProtocol`

The pattern this codebase uses, repeated across every test file:

```swift
// Core/Sources/Core/MockURLProtocol.swift
public final class MockURLProtocol: URLProtocol {
    public static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let handler = MockURLProtocol.handler else { ... }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    public override func stopLoading() {}

    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

Used like:

```swift
// Core/Tests/CoreTests/HTTPClientTests.swift
@Test func attachesBasicAuthHeader() async throws {
    var capturedAuth: String?
    MockURLProtocol.handler = { req in
        capturedAuth = req.value(forHTTPHeaderField: "Authorization")
        return (ok(req.url!), Data())
    }
    let client = HTTPClient(
        session: MockURLProtocol.session(),
        credentials: .init(username: "alice", password: "secret")
    )
    _ = try await client.data(for: URLRequest(url: URL(string: "https://x/y")!))
    #expect(capturedAuth == "Basic YWxpY2U6c2VjcmV0")
}
```

### Why this beats third-party HTTP mocks

- Zero deps.
- Inspect any request property (method, headers, URL, body stream).
- Force any response shape, including malformed JSON, 5xx, or transport errors.
- Works with anything that uses URLSession (Readium, OPDS, KOSync, Kobo).

### Static handler caveat

`MockURLProtocol.handler` is a **static `var`**. Tests sharing it must run **sequentially**:

```swift
@Suite("HTTPClient", .serialized)
struct HTTPClientTests { ... }
```

And `Makefile` runs `swift test --no-parallel` (`CLAUDE.md` records this). See [`testing.md`](testing.md) for details.

### Inspecting PUT/POST bodies

URLProtocol delivers request bodies via `httpBodyStream`, not `httpBody`. Drain it:

```swift
// Core/Sources/Core/MockURLProtocol.swift
public extension URLRequest {
    func readBodyStream() -> Data {
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: 4096)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
```

## Error mapping

One error enum, mapped at the HTTP boundary:

```swift
// Core/Sources/Core/HTTPError.swift
public enum HTTPError: Error, Equatable {
    case malformedResponse
    case unauthorized
    case notFound
    case server(status: Int, body: Data)
    case transport(URLError)
}
```

Callers catch `HTTPError`. They don't see `URLError` or raw status codes — the client translates everything.

This is the **anti-corruption layer** pattern: the wire format is messy; what flows into business code is cleaned up.

## Cancellation

Tasks cancel cooperatively. `URLSession.shared.data(...)` honors cancellation:

```swift
let downloadTask = Task {
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        process(data)
    } catch is CancellationError {
        // cleanup
    }
}

// later:
downloadTask.cancel()
```

If the task is cancelled mid-request, URLSession aborts the underlying request.

SwiftUI's `.task { ... }` cancels on view disappear, so:

```swift
.task {
    // auto-cancelled if user navigates away
    try? await downloadSomething()
}
```

## Retry

Exponential backoff for transient failures:

```swift
func fetchWithRetry(_ request: URLRequest, attempts: Int = 3) async throws -> Data {
    var lastError: Error?
    for attempt in 1...attempts {
        do {
            let (data, _) = try await client.data(for: request)
            return data
        } catch HTTPError.transport(let urlError) where urlError.isTransient {
            lastError = HTTPError.transport(urlError)
            let delayNs = UInt64(pow(2.0, Double(attempt - 1)) * 200_000_000)
            try await Task.sleep(nanoseconds: delayNs)
        }
    }
    throw lastError ?? HTTPError.malformedResponse
}
```

This codebase doesn't retry — sync flushes leave `pendingUpload = true` and rely on the next foreground scene-phase tick to retry. See `SyncService.flushAllPending` in `Kios/Services/SyncService.swift`. That's the right call for a sync app: less code, equally correct.

## Background sessions

For long-running uploads/downloads that should continue when the app is backgrounded:

```swift
let config = URLSessionConfiguration.background(withIdentifier: "com.raphi011.kios.bg")
config.sessionSendsLaunchEvents = true
let bgSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
```

The system can relaunch the app to deliver completion. Implement `URLSessionDelegate.urlSessionDidFinishEvents(forBackgroundURLSession:)` and call the system's completion handler from `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.

This codebase doesn't use background sessions — book downloads are foreground-only, on the order of seconds. If you add this for large media downloads, plan the AppDelegate plumbing.

## JSON encoding/decoding

Use `Codable`. Use `JSONDecoder.dateDecodingStrategy`. Make your DTOs `Sendable`:

```swift
public struct KoboProgressEnvelope: Codable, Sendable, Equatable {
    public let document: String
    public let progress: String
    public let percentage: Double
    public let device: String
    public let deviceID: String
}
```

If wire keys differ from Swift property names, use `CodingKeys`:

```swift
enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case document, progress, percentage, device
}
```

Or set `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` globally.

## Sendable conformance

A client that crosses actor boundaries needs to be `Sendable`. The codebase's pattern: value-typed clients that share a `URLSession` (which is itself `Sendable`):

```swift
public struct HTTPClient: Sendable { ... }
public struct KOSyncClient: Sendable { ... }
public struct KoboClient: Sendable { ... }
```

When state is needed (caches, retries), prefer an `actor`:

```swift
actor TokenRefresher {
    private var cachedToken: String?
    func token() async -> String { ... }
}
```

## Patterns from this codebase

### Layered clients

`HTTPClient` is the low-level transport. `KOSyncClient`, `KoboClient`, `OPDSClient` are domain clients that own an `HTTPClient` and translate domain calls (`fetchProgress(documentHash:)`) into `URLRequest`s.

```
URLSession  ←  HTTPClient  ←  KOSyncClient  ←  KOSyncBackend  ←  SyncService
                                                                  (UI / SwiftData)
```

Each layer has a clear job. Tests can mock at any layer by injecting a different session, client, or backend.

### Protocol-based backends

```swift
// Core/Sources/Core/SyncBackend.swift
public protocol SyncBackend: Sendable {
    func fetchProgress(for identity: BookIdentity) async throws -> CanonicalProgress?
    func pushProgress(_ canonical: CanonicalProgress, for identity: BookIdentity) async throws
}
```

`KOSyncBackend` and `KoboBackend` both conform. `SyncService` holds `any SyncBackend` and doesn't care which one it has. This is the Strategy pattern — and the right tool when you have two interchangeable implementations.

## See also

- [`testing.md`](testing.md) — `MockURLProtocol`, `@Suite(.serialized)`.
- [`swift-concurrency.md`](swift-concurrency.md) — `Sendable` for clients, `actor` for stateful workers.
- `Core/Sources/Core/HTTPClient.swift` — the canonical client.
- `Core/Sources/Core/MockURLProtocol.swift` — the canonical test seam.
