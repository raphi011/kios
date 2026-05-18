# Testing best practices

Reference for testing in this codebase. Two test surfaces:

- **`Core/Tests/CoreTests/`** — Swift Testing, runs via `swift test --no-parallel`. ~1s.
- **`KiosTests/`** — XCTest, runs via `xcodebuild test`. ~30s (simulator boot).

`make test` runs both. `make test-core` runs just the fast loop — that's the one you'll run on every change to Core.

## Why two frameworks

Swift Testing is iOS 16+ for Swift 6 toolchains and gives you `@Test`, `#expect`, parameterized tests, parallel execution, and tags. It's the future and the default for new code.

XCTest is still mandatory for:

- UI tests (`XCUIApplication`, `XCUIElement`).
- Anything that needs `setUp`/`tearDown` lifecycle hooks Swift Testing hasn't replicated.
- Anything in a target that runs in the simulator with full SwiftUI/SwiftData mount.

Rule: **Core tests in Swift Testing, iOS app tests in XCTest** until Apple closes the gap.

## Swift Testing — the API

### `@Test` and `#expect`

```swift
import Testing

@Test func twoPlusTwo() {
    #expect(2 + 2 == 4)
}
```

- `@Test` marks a test. Free function, no class needed.
- `#expect(expr)` — non-fatal assertion. Test continues on failure.
- `#require(expr)` — fatal assertion. Use when subsequent lines depend on it.

`#expect` captures the expression source and individual subexpression values in failure messages. That's the big win over `XCTAssert*` — no need to write good messages, the macro generates them.

```swift
let user = User(name: "alice", age: 30)
#expect(user.age == 31)
// Failure: "Expectation failed: (user.age → 30) == 31"
```

### Suites

```swift
@Suite("HTTPClient", .serialized)
struct HTTPClientTests {
    init() { MockURLProtocol.handler = nil }       // per-test reset

    @Test func attachesBasicAuthHeader() async throws { ... }
}
```

- `@Suite` groups related tests. A plain `struct` containing `@Test` functions also forms an implicit suite.
- `init()` runs once per test — equivalent to `setUp`.
- `deinit` runs after each test — equivalent to `tearDown`. Suites with `deinit` must be classes (`final class`), not structs.

### Traits

| Trait | Effect |
|-------|--------|
| `.serialized` | Tests in this suite run sequentially, not in parallel. |
| `.disabled("reason")` | Skip the test. The reason shows up in the report. |
| `.enabled(if: condition)` | Conditional skip. |
| `.tags(.integration)` | Tag for filtering. Define tags via `extension Tag { @Tag static var integration: Self }`. |
| `.timeLimit(.seconds(10))` | Fail if the test takes longer. |
| `.bug("https://...")` | Link to a known issue. |

### Async tests

Just add `async`:

```swift
@Test func fetchesData() async throws {
    let data = try await client.fetch()
    #expect(data.count > 0)
}
```

No `expectation`/`wait(for:)` dance. Use structured concurrency directly.

### Expected throws

```swift
@Test func throwsOn404() async {
    await #expect(throws: HTTPError.notFound) {
        _ = try await client.fetch(.notFoundURL)
    }
}
```

Or pattern-match for richer assertions:

```swift
@Test func wrapsServerError() async throws {
    do {
        _ = try await client.fetch(.serverErrorURL)
        Issue.record("expected throw")
    } catch HTTPError.server(let status, let body) {
        #expect(status == 500)
        #expect(String(data: body, encoding: .utf8) == "oops")
    }
}
```

`Issue.record(...)` is the new way to fail without throwing.

### Parameterized tests

```swift
@Test(arguments: [
    ("alice", "secret", "Basic YWxpY2U6c2VjcmV0"),
    ("bob",   "x",      "Basic Ym9iOng="),
])
func basicAuthEncoding(user: String, password: String, expected: String) {
    let creds = BasicCredentials(username: user, password: password)
    #expect(creds.authorizationHeader == expected)
}
```

Each tuple becomes a separate test case with its own row in the report.

## Patterns from this codebase

### Static mutable mock state → `.serialized` suite

```swift
// Core/Tests/CoreTests/HTTPClientTests.swift
@Suite("HTTPClient", .serialized)
struct HTTPClientTests {
    init() { MockURLProtocol.handler = nil }
    ...
}
```

`MockURLProtocol.handler` is a static `var`. Two tests running in parallel would race. `.serialized` on the suite + `--no-parallel` in the Makefile keeps this safe.

`CLAUDE.md` records this:

> Core tests must run sequentially — `MockURLProtocol.handler` is a shared static. `--no-parallel` is baked into the Makefile.

### Per-test reset via `init`

```swift
init() { MockURLProtocol.handler = nil }
```

This is the Swift Testing equivalent of `XCTestCase.setUp`. Runs before every `@Test` in the suite.

### Capturing requests

```swift
@Test func putProgressSerializesAllFields() async throws {
    var bodyJSON: [String: Any]?
    MockURLProtocol.handler = { req in
        if let stream = req.httpBodyStream {
            // drain stream into Data, parse JSON
            ...
        }
        return (ok(req.url!), Data())
    }

    let client = makeClient()
    try await client.putProgress(...)
    #expect(bodyJSON?["document"] as? String == "abc123")
}
```

`MockURLProtocol.handler` is a closure — capture whatever you want into a local `var`, run the system under test, assert on the captures. No new mocking library needed.

### Test helpers next to tests

Tiny helper functions live as static members on the suite struct:

```swift
private static func ok(_ url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
}
```

Keeps the helper at hand without polluting the production target.

## XCTest (for iOS app tests)

When you need full SwiftUI / SwiftData mount, you're in XCTest territory:

```swift
import XCTest
@testable import Kios

final class SyncServiceTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        container = try! ModelContainer.kiosInMemory()
        context = ModelContext(container)
    }

    @MainActor
    func testOnOpenReturnsUseLocalWhenServerHasNoProgress() async throws {
        let service = SyncService(
            backend: MockBackend(progress: nil),
            context: context, deviceID: "d", deviceName: "test"
        )
        let book = Book(...)
        context.insert(book)
        let action = try await service.onOpen(book: book)
        XCTAssertEqual(action, .useLocal)
    }
}
```

Notes:

- `@MainActor` on setup/tests — `ModelContext` and `@Model` instances are main-actor-bound.
- Use `ModelContainer.kiosInMemory()` for tests (see `Kios/App/ModelContainerFactory.swift`). Same schema, no disk.
- `XCTAssertEqual`, `XCTAssertThrowsError`, `XCTAssertNoThrow`, `XCTAssertNil`, etc.

## Fixtures

Sample EPUBs and OPDS payloads live in `KiosTests/Fixtures/`. Load with:

```swift
let url = Bundle(for: Self.self).url(forResource: "moby-dick", withExtension: "epub")!
```

For tests where the file content matters, prefer fixtures to inline strings.

## Async expectations (XCTest)

```swift
func testAsync() async throws {
    let result = try await service.fetch()
    XCTAssertNotNil(result)
}
```

The `XCTestExpectation` / `wait(for:)` pattern is legacy. Always prefer `async throws` test methods.

## Snapshot testing

Not currently used in this codebase. If you add it:

- Swift Testing supports custom inline expectations — works for snapshots without a library.
- `pointfreeco/swift-snapshot-testing` is the de facto third-party.
- For Readium reader rendering, snapshot the surrounding chrome only — the WKWebView body is non-deterministic.

## UI testing

Not currently used. The `Visual verification` section of `CLAUDE.md` documents a workaround:

> Cycle: `xcodebuild … build && xcrun simctl terminate $SIM …kios; xcrun simctl install $SIM <app> && xcrun simctl launch $SIM com.raphi011.kios`
> No CLI tap/scroll exists; AppleScript needs Accessibility — to view non-default tabs/states, temporarily flip `@State` defaults (e.g. `selectedTab`, `uiVisible`) and revert before committing.

If you grow into XCUITest, the typical structure is `XCUIApplication().launch()` → `.buttons["..."].tap()` → `XCTAssertTrue(.staticTexts["..."].exists)`.

## Coverage

Not gathered by default — `project.yml:73` sets `gatherCoverageData: false`. Turn it on per-run with `xcodebuild test -enableCodeCoverage YES` if you want a one-off coverage report. Don't enable it permanently — it slows builds without much payoff for this size of project.

## What to test

- **Always**: parsers, serializers, mappers, predicate logic, business rules in `Core/`. They have no side effects, run in 1s, and break on schema changes.
- **Often**: protocol backends behind a `URLProtocol` mock (KOSync, Kobo, OPDS).
- **Sometimes**: services that wire `Core` to SwiftData (`SyncService`, `LibraryService`) — use in-memory `ModelContainer`.
- **Rarely**: SwiftUI views. Hard to test in isolation, brittle, and `View.body` is mostly composition. Trust the visual verification loop.

## Anti-patterns

- Sharing a mock's state across tests without `.serialized` + per-test reset.
- Testing `View.body` rendering — snapshot-test the wrapping chrome instead.
- Hitting the network in unit tests. If it isn't `MockURLProtocol`-mocked, it's an integration test — and integration tests should live in a separate target, run on demand, not in `make test`.
- `XCTestExpectation` in new code. Use `async`/`await`.

## See also

- [`networking.md`](networking.md) — `MockURLProtocol` deep-dive.
- [`swiftdata.md`](swiftdata.md) — `kiosInMemory()` container for tests.
- `Makefile` — `test`, `test-core`, `test-ios` targets.
