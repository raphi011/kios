# Multi-Protocol Sync Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Kobo Sync backend (CWA `/kobo/<token>` blueprint) alongside the existing kosync backend, behind a protocol abstraction. Users pick the active protocol in Settings; everything else is backend-agnostic.

**Architecture:** Two protocol-agnostic interfaces (`SyncBackend`, `CatalogBackend`) in `Core/` with two implementations: `KOSyncBackend + OPDSClient` (refactor of existing code) and `KoboBackend` (new — provides both). `Book` model carries both per-protocol IDs; `ReadingProgress` carries both per-protocol raw payloads and a canonical Readium-shape locator. A `BackendFactory` builds the active pair from `AuthStore.activeProtocol`. Protocol pinning on buffered uploads prevents data loss across mode switches.

**Tech Stack:** Swift 5.10, Foundation (`Core/`), SwiftData (iOS), URLSession, Codable, Swift Testing. iOS 17+.

**Companion docs:** `docs/superpowers/specs/2026-05-11-multi-protocol-sync-design.md` (spec), `docs/calibre-web.md` (cluster-side CWA notes), `docs/research.md` §2 (protocol research).

---

## Phasing

| Phase | Outcome |
|---|---|
| 0. Refactor seam | `BookFormat` lives in `Core`; existing kosync code moves into `Core/KOSync/`; build and tests still green |
| 1. Abstractions | `SyncBackend`, `CatalogBackend`, canonical types defined and tested |
| 2. Kobo wire types | `KoboTypes.swift` with tolerant decoding (stray entries, varying `Contributors`) |
| 3. KoboClient | All v1 endpoints unit-tested with `MockURLProtocol` |
| 4. KoboProgressMapper | Round-trip vectors |
| 5. Backend implementations | `KOSyncBackend`, `KoboBackend` |
| 6. SwiftData V2 | Migration + backfills, model changes |
| 7. Factory + services | `BackendFactory`, refactored `SyncService` with protocol pinning |
| 8. Library mode-switch | Book matching, archive flag |
| 9. Settings UI | Protocol picker, validated test-connection |
| 10. Docs + smoke | README updates, manual smoke checklist |

Each phase ends green.

---

## Phase 0: Refactor seam

### Task 0.1: Move `BookFormat` into `Core`

**Files:**
- Move: `iOSReader/Models/BookFormat.swift` → `Core/Sources/Core/Models/BookFormat.swift`
- Modify: any `import` site that referenced the iOS-target type — Swift compiler will surface them.

- [ ] **Step 1: Read the current `BookFormat`**

```bash
cat ~/Git/ios-reader/iOSReader/Models/BookFormat.swift
```

- [ ] **Step 2: Move the file**

```bash
cd ~/Git/ios-reader
mkdir -p Core/Sources/Core/Models
git mv iOSReader/Models/BookFormat.swift Core/Sources/Core/Models/BookFormat.swift
```

- [ ] **Step 3: Mark the type `public` so `iOSReader` can use it**

Edit `Core/Sources/Core/Models/BookFormat.swift`: change `enum BookFormat` → `public enum BookFormat` and add `public` to each case if needed. Add `public init?(rawValue: String)` if the synthesized one is internal.

- [ ] **Step 4: Build Core and iOS**

```bash
cd ~/Git/ios-reader
make test-core
xcodegen generate
xcodebuild -scheme iOSReader -destination "platform=iOS Simulator,name=iPhone 16" build 2>&1 | tail -20
```

Fix any `Cannot find type 'BookFormat'` by adding `import Core` to the affected iOSReader files (likely `Book.swift`, OPDS/Download services).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(sync): move BookFormat into Core for cross-target use"
```

---

### Task 0.2: Move existing kosync code into `Core/Sources/Core/KOSync/`

**Files:**
- Move: `Core/Sources/Core/KOSyncClient.swift` → `Core/Sources/Core/KOSync/KOSyncClient.swift`
- Move: `Core/Sources/Core/ProgressMapper.swift` → `Core/Sources/Core/KOSync/KOSyncProgressMapper.swift`
- Modify: any test file referencing `ProgressMapper` — rename to `KOSyncProgressMapper`.

- [ ] **Step 1: Move files**

```bash
cd ~/Git/ios-reader
mkdir -p Core/Sources/Core/KOSync
git mv Core/Sources/Core/KOSyncClient.swift Core/Sources/Core/KOSync/KOSyncClient.swift
git mv Core/Sources/Core/ProgressMapper.swift Core/Sources/Core/KOSync/KOSyncProgressMapper.swift
```

- [ ] **Step 2: Rename the enum**

In `Core/Sources/Core/KOSync/KOSyncProgressMapper.swift`:
- Replace `public enum ProgressMapper {` → `public enum KOSyncProgressMapper {`
- Update the doc comment to mention this is the kosync-specific mapper.

- [ ] **Step 3: Update references**

```bash
cd ~/Git/ios-reader
grep -rln "ProgressMapper" Core iOSReader iOSReaderTests
```

For each hit, replace `ProgressMapper.` with `KOSyncProgressMapper.` (the type's static methods only — file paths in comments are fine to leave).

- [ ] **Step 4: Build and test**

```bash
make test-core
make test-ios
```

Both should pass. If any test fails for an unrelated reason, stop and investigate before continuing.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(sync): namespace kosync code under Core/KOSync"
```

---

## Phase 1: Abstractions

### Task 1.1: Define `BookIdentity`, `CanonicalProgress`, `BackendError`

**Files:**
- Create: `Core/Sources/Core/SyncBackend.swift`
- Create: `Core/Tests/CoreTests/SyncBackendTypesTests.swift`

- [ ] **Step 1: Write failing test for `BookIdentity` equality and hashability**

`Core/Tests/CoreTests/SyncBackendTypesTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

struct SyncBackendTypesTests {
    @Test func bookIdentityEquatable() {
        let a = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
        let b = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
        let c = BookIdentity(partialMD5: nil, koboBookUUID: "xyz")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func canonicalProgressRoundTrip() {
        let p = CanonicalProgress(
            percentage: 0.42,
            locatorJSON: #"{"href":"a"}"#,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "dev",
            deviceName: "iPhone"
        )
        #expect(p.percentage == 0.42)
        #expect(p.locatorJSON == #"{"href":"a"}"#)
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

```bash
cd ~/Git/ios-reader && make test-core
```

Expected: `Cannot find 'BookIdentity' in scope`.

- [ ] **Step 3: Implement the types**

`Core/Sources/Core/SyncBackend.swift`:

```swift
import Foundation

public struct BookIdentity: Sendable, Hashable {
    public let partialMD5: String?
    public let koboBookUUID: String?

    public init(partialMD5: String? = nil, koboBookUUID: String? = nil) {
        self.partialMD5 = partialMD5
        self.koboBookUUID = koboBookUUID
    }
}

public struct CanonicalProgress: Sendable, Equatable {
    public let percentage: Double
    public let locatorJSON: String?
    public let timestamp: Date
    public let deviceID: String
    public let deviceName: String

    public init(
        percentage: Double,
        locatorJSON: String?,
        timestamp: Date,
        deviceID: String,
        deviceName: String
    ) {
        self.percentage = percentage
        self.locatorJSON = locatorJSON
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public enum BackendError: Error, Sendable, Equatable {
    case identityMissing(field: String)
    case authenticationFailed
    case serverShapeUnexpected(detail: String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(URLErrorCode)

    /// Wrapper avoiding URLError's non-Equatable conformance.
    public struct URLErrorCode: Sendable, Equatable {
        public let rawValue: Int
        public init(_ urlError: URLError) { self.rawValue = urlError.code.rawValue }
        public init(rawValue: Int) { self.rawValue = rawValue }
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/Core/SyncBackend.swift Core/Tests/CoreTests/SyncBackendTypesTests.swift
git commit -m "feat(sync): add canonical sync types (BookIdentity, CanonicalProgress)"
```

---

### Task 1.2: Define `SyncBackend` protocol

**Files:**
- Modify: `Core/Sources/Core/SyncBackend.swift` (append)
- Modify: `Core/Tests/CoreTests/SyncBackendTypesTests.swift` (append test)

- [ ] **Step 1: Write failing test that a fake `SyncBackend` can be called**

Append to `SyncBackendTypesTests.swift`:

```swift
@Test func syncBackendProtocolCallable() async throws {
    let backend: any SyncBackend = FakeSyncBackend()
    try await backend.authenticate()
    let id = BookIdentity(partialMD5: "abc", koboBookUUID: nil)
    let progress = try await backend.fetchProgress(for: id)
    #expect(progress == nil)
}

private struct FakeSyncBackend: SyncBackend {
    func authenticate() async throws {}
    func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? { nil }
    func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {}
}
```

- [ ] **Step 2: Run test, confirm fail**

Expected: `Cannot find type 'SyncBackend' in scope`.

- [ ] **Step 3: Add the protocol to `SyncBackend.swift`**

```swift
public protocol SyncBackend: Sendable {
    func authenticate() async throws
    func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress?
    func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws
}
```

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): add SyncBackend protocol"
```

---

### Task 1.3: Define `CatalogBackend` protocol + `CatalogEntry`

**Files:**
- Create: `Core/Sources/Core/CatalogBackend.swift`
- Create: `Core/Tests/CoreTests/CatalogBackendTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Core

struct CatalogBackendTests {
    @Test func entryConstruction() {
        let entry = CatalogEntry(
            serverID: "id-1",
            title: "Test",
            authors: ["A"],
            identity: BookIdentity(koboBookUUID: "uuid"),
            downloadURL: URL(string: "https://example.com/d")!,
            format: .epub,
            thumbnailURL: nil
        )
        #expect(entry.title == "Test")
        #expect(entry.identity.koboBookUUID == "uuid")
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`Core/Sources/Core/CatalogBackend.swift`:

```swift
import Foundation

public struct CatalogEntry: Sendable, Equatable {
    public let serverID: String
    public let title: String
    public let authors: [String]
    public let identity: BookIdentity
    public let downloadURL: URL
    public let format: BookFormat
    public let thumbnailURL: URL?

    public init(
        serverID: String,
        title: String,
        authors: [String],
        identity: BookIdentity,
        downloadURL: URL,
        format: BookFormat,
        thumbnailURL: URL?
    ) {
        self.serverID = serverID
        self.title = title
        self.authors = authors
        self.identity = identity
        self.downloadURL = downloadURL
        self.format = format
        self.thumbnailURL = thumbnailURL
    }
}

public protocol CatalogBackend: Sendable {
    func listLibrary() async throws -> [CatalogEntry]
    func resolveDownload(for entry: CatalogEntry) async throws -> URL
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/Core/CatalogBackend.swift Core/Tests/CoreTests/CatalogBackendTests.swift
git commit -m "feat(sync): add CatalogBackend protocol + CatalogEntry"
```

---

## Phase 2: Kobo wire types

### Task 2.1: Kobo `Location`, `CurrentBookmark`, `StatusInfo`, `Statistics`, `ReadingState`

**Files:**
- Create: `Core/Sources/Core/Kobo/KoboTypes.swift`
- Create: `Core/Tests/CoreTests/KoboTypesTests.swift`

- [ ] **Step 1: Write failing test for `KoboReadingState` decoding**

```swift
import Testing
import Foundation
@testable import Core

struct KoboTypesTests {
    @Test func readingStateDecodesFullPayload() throws {
        let json = """
        {
          "EntitlementId": "uuid-1",
          "Created": "2026-05-01T00:00:00Z",
          "LastModified": "2026-05-11T20:36:34Z",
          "PriorityTimestamp": "2026-05-11T20:36:34Z",
          "StatusInfo": {
            "LastModified": "2026-05-11T20:36:34Z",
            "Status": "Reading",
            "TimesStartedReading": 1
          },
          "Statistics": {
            "LastModified": "2026-05-11T20:36:34Z",
            "SpentReadingMinutes": 42,
            "RemainingTimeMinutes": 120
          },
          "CurrentBookmark": {
            "LastModified": "2026-05-11T20:36:34Z",
            "ProgressPercent": 45.0,
            "ContentSourceProgressPercent": 16.0,
            "Location": {
              "Value": "kobo.10.1",
              "Type": "KoboSpan",
              "Source": "f_0035.xhtml"
            }
          }
        }
        """.data(using: .utf8)!

        let state = try KoboDecoder.decode(KoboReadingState.self, from: json)
        #expect(state.entitlementId == "uuid-1")
        #expect(state.statusInfo?.status == .reading)
        #expect(state.currentBookmark?.progressPercent == 45.0)
        #expect(state.currentBookmark?.location?.value == "kobo.10.1")
    }

    @Test func readingStateOmittingOptionalFieldsDecodes() throws {
        let json = """
        {
          "EntitlementId": "uuid-1",
          "Created": "2026-05-01T00:00:00Z",
          "LastModified": "2026-05-11T20:36:34Z",
          "PriorityTimestamp": "2026-05-11T20:36:34Z",
          "StatusInfo": {
            "LastModified": "2026-05-11T20:36:34Z",
            "Status": "ReadyToRead",
            "TimesStartedReading": 0
          },
          "Statistics": { "LastModified": "2026-05-11T20:36:34Z" },
          "CurrentBookmark": { "LastModified": "2026-05-11T20:36:34Z" }
        }
        """.data(using: .utf8)!

        let state = try KoboDecoder.decode(KoboReadingState.self, from: json)
        #expect(state.currentBookmark?.progressPercent == nil)
        #expect(state.currentBookmark?.location == nil)
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement the types**

`Core/Sources/Core/Kobo/KoboTypes.swift`:

```swift
import Foundation

public enum KoboReadingStatus: String, Codable, Sendable {
    case reading = "Reading"
    case finished = "Finished"
    case readyToRead = "ReadyToRead"
}

public struct KoboLocation: Codable, Sendable, Equatable {
    public let value: String
    public let type: String
    public let source: String

    enum CodingKeys: String, CodingKey { case value = "Value", type = "Type", source = "Source" }
}

public struct KoboCurrentBookmark: Codable, Sendable, Equatable {
    public let lastModified: String
    public let progressPercent: Double?
    public let contentSourceProgressPercent: Double?
    public let location: KoboLocation?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case progressPercent = "ProgressPercent"
        case contentSourceProgressPercent = "ContentSourceProgressPercent"
        case location = "Location"
    }
}

public struct KoboStatusInfo: Codable, Sendable, Equatable {
    public let lastModified: String
    public let status: KoboReadingStatus
    public let timesStartedReading: Int
    public let lastTimeStartedReading: String?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case status = "Status"
        case timesStartedReading = "TimesStartedReading"
        case lastTimeStartedReading = "LastTimeStartedReading"
    }
}

public struct KoboStatistics: Codable, Sendable, Equatable {
    public let lastModified: String
    public let spentReadingMinutes: Int?
    public let remainingTimeMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case lastModified = "LastModified"
        case spentReadingMinutes = "SpentReadingMinutes"
        case remainingTimeMinutes = "RemainingTimeMinutes"
    }
}

public struct KoboReadingState: Codable, Sendable, Equatable {
    public let entitlementId: String
    public let created: String
    public let lastModified: String
    public let priorityTimestamp: String
    public let statusInfo: KoboStatusInfo?
    public let statistics: KoboStatistics?
    public let currentBookmark: KoboCurrentBookmark?

    enum CodingKeys: String, CodingKey {
        case entitlementId = "EntitlementId"
        case created = "Created"
        case lastModified = "LastModified"
        case priorityTimestamp = "PriorityTimestamp"
        case statusInfo = "StatusInfo"
        case statistics = "Statistics"
        case currentBookmark = "CurrentBookmark"
    }
}

/// Shared decoder configured for CWA's Kobo blueprint timestamp shape.
public enum KoboDecoder {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/Core/Kobo/KoboTypes.swift Core/Tests/CoreTests/KoboTypesTests.swift
git commit -m "feat(sync): add Kobo wire types (ReadingState, Bookmark, Location)"
```

---

### Task 2.2: Kobo `Contributors` tolerant decoding

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboTypes.swift`
- Modify: `Core/Tests/CoreTests/KoboTypesTests.swift`

- [ ] **Step 1: Write failing tests for both shapes**

Append to `KoboTypesTests.swift`:

```swift
@Test func contributorsAsStringArray() throws {
    let json = #"{"Contributors": ["Felienne Hermans", "Jane Doe"]}"#.data(using: .utf8)!
    let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
    #expect(bag.contributors == ["Felienne Hermans", "Jane Doe"])
}

@Test func contributorsAsObjectArray() throws {
    let json = #"{"Contributors": [{"Name": "Felienne Hermans", "Role": "Author"}]}"#.data(using: .utf8)!
    let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
    #expect(bag.contributors == ["Felienne Hermans"])
}

@Test func contributorsAbsent() throws {
    let json = "{}".data(using: .utf8)!
    let bag = try KoboDecoder.decode(KoboContributorBag.self, from: json)
    #expect(bag.contributors == [])
}

private struct KoboContributorBag: Decodable {
    let contributors: [String]
    enum CodingKeys: String, CodingKey { case contributors = "Contributors" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contributors = try c.decodeContributors(forKey: .contributors)
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

Expected: `decodeContributors(forKey:)` doesn't exist.

- [ ] **Step 3: Implement the extension**

Append to `KoboTypes.swift`:

```swift
public extension KeyedDecodingContainer {
    /// Decodes a `Contributors` field that is either a list of strings or a
    /// list of `{Name: "..."}` objects. Returns `[]` if absent.
    func decodeContributors(forKey key: Key) throws -> [String] {
        guard contains(key) else { return [] }
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }
        struct Contributor: Decodable {
            let name: String
            enum CodingKeys: String, CodingKey { case name = "Name" }
        }
        let objects = try decode([Contributor].self, forKey: key)
        return objects.map(\.name)
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): tolerant Contributors decoding (string array or object array)"
```

---

### Task 2.3: Kobo sync entry tolerance

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboTypes.swift`
- Modify: `Core/Tests/CoreTests/KoboTypesTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func syncEntryParsingSkipsStrayStringEntry() throws {
    let json = #"""
    [
      { "ChangedReadingState": { "ReadingState": { "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x","StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},"Statistics":{"LastModified":"x"},"CurrentBookmark":{"LastModified":"x"} } } },
      "ResponseStatus",
      { "DeletedTag": { "Tag": { "Id": "t1", "LastModified": "x" } } },
      { "SomethingUnknown": { "Field": 1 } }
    ]
    """#.data(using: .utf8)!

    let entries = try KoboDecoder.decode([KoboSyncEntry?].self, from: json).compactMap { $0 }
    #expect(entries.count == 2)
    if case .changedReadingState(let rs) = entries[0] {
        #expect(rs.entitlementId == "u1")
    } else {
        Issue.record("expected changedReadingState first")
    }
    if case .deletedTag = entries[1] {
        // good
    } else {
        Issue.record("expected deletedTag second")
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Add `KoboSyncEntry` enum with tolerant decoding**

Append to `KoboTypes.swift`:

```swift
public enum KoboSyncEntry: Sendable {
    case newEntitlement(KoboEntitlement)
    case changedEntitlement(KoboEntitlement)
    case changedReadingState(KoboReadingState)
    case newTag       // ignored content
    case changedTag   // ignored content
    case deletedTag   // ignored content
}

public struct KoboEntitlement: Sendable {
    public let bookEntitlement: KoboBookEntitlement
    public let bookMetadata: KoboBookMetadata
    public let readingState: KoboReadingState?
}

public struct KoboBookEntitlement: Codable, Sendable {
    public let id: String
    public let crossRevisionId: String
    public let revisionId: String
    public let accessibility: String
    public let status: String
    public let isRemoved: Bool
    public let created: String
    public let lastModified: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case crossRevisionId = "CrossRevisionId"
        case revisionId = "RevisionId"
        case accessibility = "Accessibility"
        case status = "Status"
        case isRemoved = "IsRemoved"
        case created = "Created"
        case lastModified = "LastModified"
    }
}

public struct KoboBookMetadata: Sendable {
    public let entitlementId: String
    public let title: String
    public let contributors: [String]
    public let coverImageId: String?
    public let language: String?
    public let description: String?
    public let downloadUrls: [KoboDownloadURL]
}

extension KoboBookMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case entitlementId = "EntitlementId"
        case title = "Title"
        case coverImageId = "CoverImageId"
        case language = "Language"
        case description = "Description"
        case downloadUrls = "DownloadUrls"
        case contributors = "Contributors"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entitlementId = try c.decode(String.self, forKey: .entitlementId)
        title = try c.decode(String.self, forKey: .title)
        coverImageId = try c.decodeIfPresent(String.self, forKey: .coverImageId)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        downloadUrls = try c.decodeIfPresent([KoboDownloadURL].self, forKey: .downloadUrls) ?? []
        contributors = try c.decodeContributors(forKey: .contributors)
    }
}

public struct KoboDownloadURL: Codable, Sendable, Equatable {
    public let format: String   // "KEPUB" | "EPUB" | "EPUB3" | "EPUB3FL"
    public let url: URL
    public let size: Int?
    public let platform: String?

    enum CodingKeys: String, CodingKey {
        case format = "Format", url = "Url", size = "Size", platform = "Platform"
    }
}

extension KoboEntitlement: Decodable {
    enum CodingKeys: String, CodingKey {
        case bookEntitlement = "BookEntitlement"
        case bookMetadata = "BookMetadata"
        case readingState = "ReadingState"
    }
}

/// One element of the `/v1/library/sync` array. Decoded as Optional so that
/// non-dict / unknown-shape entries become `nil` and callers can compactMap.
extension Array where Element == KoboSyncEntry? {
    // Using array conformance enables decoding the top-level array directly.
}

extension Optional: Decodable where Wrapped == KoboSyncEntry {
    public init(from decoder: Decoder) throws {
        // Skip non-dict entries (CWA can emit stray strings)
        guard let container = try? decoder.container(keyedBy: SyncEntryKey.self) else {
            self = .none
            return
        }
        let keys = container.allKeys
        guard !keys.isEmpty else {
            self = .none
            return
        }
        let key = keys[0]
        switch key.stringValue {
        case "NewEntitlement":
            let e = try container.decode(KoboEntitlement.self, forKey: key)
            self = .some(.newEntitlement(e))
        case "ChangedEntitlement":
            let e = try container.decode(KoboEntitlement.self, forKey: key)
            self = .some(.changedEntitlement(e))
        case "ChangedReadingState":
            struct Wrapper: Decodable {
                let readingState: KoboReadingState
                enum CodingKeys: String, CodingKey { case readingState = "ReadingState" }
            }
            let w = try container.decode(Wrapper.self, forKey: key)
            self = .some(.changedReadingState(w.readingState))
        case "NewTag":      self = .some(.newTag)
        case "ChangedTag":  self = .some(.changedTag)
        case "DeletedTag":  self = .some(.deletedTag)
        default:            self = .none
        }
    }
}

private struct SyncEntryKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil as Int? != nil ? nil : nil; return nil }
}
```

> Note: the `Optional: Decodable where Wrapped == KoboSyncEntry` extension is the
> Swift idiom for "decode some array element as Optional so the JSONDecoder
> tolerates failures per element." If the iOS target doesn't like extending
> `Optional`, fall back to a `KoboSyncEntryOrSkip` newtype wrapper.

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): tolerant Kobo sync entry decoder (skips stray non-dict)"
```

---

### Task 2.4: Kobo PUT-state payload (`KoboStateUpdate`)

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboTypes.swift`
- Modify: `Core/Tests/CoreTests/KoboTypesTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func stateUpdateEncodesCorrectly() throws {
    let update = KoboStateUpdate(readingStates: [
        .init(
            currentBookmark: .init(
                progressPercent: 45.0,
                contentSourceProgressPercent: 16.0,
                location: .init(value: "kobo.10.1", type: "KoboSpan", source: "f_0035.xhtml")
            ),
            statusInfo: .init(status: .reading),
            statistics: nil
        )
    ])
    let data = try JSONEncoder().encode(update)
    let s = String(data: data, encoding: .utf8)!
    #expect(s.contains("\"ReadingStates\":["))
    #expect(s.contains("\"ProgressPercent\":45"))
    #expect(s.contains("\"Value\":\"kobo.10.1\""))
    #expect(s.contains("\"Status\":\"Reading\""))
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

Append to `KoboTypes.swift`:

```swift
public struct KoboStateUpdate: Encodable, Sendable {
    public let readingStates: [State]

    public struct State: Encodable, Sendable {
        public let currentBookmark: Bookmark?
        public let statusInfo: StatusInfo?
        public let statistics: Statistics?

        public struct Bookmark: Encodable, Sendable {
            public let progressPercent: Double
            public let contentSourceProgressPercent: Double
            public let location: KoboLocation?

            enum CodingKeys: String, CodingKey {
                case progressPercent = "ProgressPercent"
                case contentSourceProgressPercent = "ContentSourceProgressPercent"
                case location = "Location"
            }

            public init(progressPercent: Double, contentSourceProgressPercent: Double, location: KoboLocation?) {
                self.progressPercent = progressPercent
                self.contentSourceProgressPercent = contentSourceProgressPercent
                self.location = location
            }
        }

        public struct StatusInfo: Encodable, Sendable {
            public let status: KoboReadingStatus
            enum CodingKeys: String, CodingKey { case status = "Status" }
            public init(status: KoboReadingStatus) { self.status = status }
        }

        public struct Statistics: Encodable, Sendable {
            public let spentReadingMinutes: Int
            public let remainingTimeMinutes: Int
            enum CodingKeys: String, CodingKey {
                case spentReadingMinutes = "SpentReadingMinutes"
                case remainingTimeMinutes = "RemainingTimeMinutes"
            }
            public init(spentReadingMinutes: Int, remainingTimeMinutes: Int) {
                self.spentReadingMinutes = spentReadingMinutes
                self.remainingTimeMinutes = remainingTimeMinutes
            }
        }

        enum CodingKeys: String, CodingKey {
            case currentBookmark = "CurrentBookmark"
            case statusInfo = "StatusInfo"
            case statistics = "Statistics"
        }

        public init(currentBookmark: Bookmark?, statusInfo: StatusInfo?, statistics: Statistics?) {
            self.currentBookmark = currentBookmark
            self.statusInfo = statusInfo
            self.statistics = statistics
        }
    }

    public init(readingStates: [State]) { self.readingStates = readingStates }

    enum CodingKeys: String, CodingKey { case readingStates = "ReadingStates" }
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): add KoboStateUpdate encoder"
```

---

## Phase 3: KoboClient

### Task 3.1: `KoboClient.initialization()`

**Files:**
- Create: `Core/Sources/Core/Kobo/KoboClient.swift`
- Create: `Core/Tests/CoreTests/KoboClientTests.swift`

- [ ] **Step 1: Write failing test using `MockURLProtocol`**

```swift
import Testing
import Foundation
@testable import Core

@MainActor
struct KoboClientTests {
    @Test func initializationReturnsResources() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/kobo/TOKEN/v1/initialization")
            let body = #"{ "Resources": { "image_url_template": "https://cwa/{ImageId}/{width}/{height}/false/image.jpg" } }"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body.data(using: .utf8)!
            )
        }

        let http = HTTPClient.mocked()
        let base = URL(string: "https://cwa/kobo/TOKEN")!
        let client = KoboClient(baseURL: base, http: http)
        let res = try await client.initialization()
        #expect(res.imageURLTemplate.contains("{ImageId}"))
    }
}
```

(Assumes `HTTPClient.mocked()` exists — confirm in the existing test helpers. If not, the test sets up its own URLSession with the `MockURLProtocol` injected.)

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`Core/Sources/Core/Kobo/KoboClient.swift`:

```swift
import Foundation

public struct KoboInitResources: Sendable, Codable {
    public let imageURLTemplate: String

    enum CodingKeys: String, CodingKey { case imageURLTemplate = "image_url_template" }
}

public struct KoboClient: Sendable {
    public let baseURL: URL
    public let http: HTTPClient

    public init(baseURL: URL, http: HTTPClient) {
        self.baseURL = baseURL
        self.http = http
    }

    public func initialization() async throws -> KoboInitResources {
        let url = baseURL.appendingPathComponent("v1/initialization")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, _) = try await http.data(for: req)
        struct Envelope: Decodable { let resources: KoboInitResources
            enum CodingKeys: String, CodingKey { case resources = "Resources" }
        }
        return try KoboDecoder.decode(Envelope.self, from: data).resources
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

```bash
make test-core
```

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/Core/Kobo/KoboClient.swift Core/Tests/CoreTests/KoboClientTests.swift
git commit -m "feat(sync): KoboClient.initialization()"
```

---

### Task 3.2: `KoboClient.librarySync()` with pagination

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboClient.swift`
- Modify: `Core/Tests/CoreTests/KoboClientTests.swift`

- [ ] **Step 1: Write failing test for single-page sync**

Append:

```swift
@Test func librarySyncSinglePage() async throws {
    var callCount = 0
    MockURLProtocol.handler = { req in
        callCount += 1
        #expect(req.url?.path == "/kobo/TOKEN/v1/library/sync")
        // No prior token expected on first call
        #expect(req.value(forHTTPHeaderField: "x-kobo-synctoken") == nil)
        let body = #"""
        [
          { "DeletedTag": { "Tag": { "Id": "t1", "LastModified": "x" } } },
          "ResponseStatus"
        ]
        """#
        let resp = HTTPURLResponse(
            url: req.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "x-kobo-synctoken": "TOKEN_A",
                "x-kobo-sync": "None"
            ]
        )!
        return (resp, body.data(using: .utf8)!)
    }

    let client = KoboClient(baseURL: URL(string: "https://cwa/kobo/TOKEN")!, http: .mocked())
    let result = try await client.librarySync(syncToken: nil)
    #expect(callCount == 1)
    #expect(result.entries.count == 1)   // stray skipped
    #expect(result.nextSyncToken == "TOKEN_A")
}

@Test func librarySyncFollowsContinueHeader() async throws {
    var callCount = 0
    MockURLProtocol.handler = { req in
        callCount += 1
        if callCount == 1 {
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["x-kobo-synctoken": "T1", "x-kobo-sync": "continue"])!
            return (resp, "[]".data(using: .utf8)!)
        }
        #expect(req.value(forHTTPHeaderField: "x-kobo-synctoken") == "T1")
        let resp = HTTPURLResponse(
            url: req.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["x-kobo-synctoken": "T2", "x-kobo-sync": "None"])!
        return (resp, "[]".data(using: .utf8)!)
    }
    let client = KoboClient(baseURL: URL(string: "https://cwa/kobo/TOKEN")!, http: .mocked())
    let result = try await client.librarySync(syncToken: nil)
    #expect(callCount == 2)
    #expect(result.nextSyncToken == "T2")
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

Append to `KoboClient.swift`:

```swift
public struct KoboLibrarySyncResult: Sendable {
    public let entries: [KoboSyncEntry]
    public let nextSyncToken: String?
}

public extension KoboClient {
    func librarySync(syncToken: String?) async throws -> KoboLibrarySyncResult {
        var allEntries: [KoboSyncEntry] = []
        var token = syncToken

        while true {
            let url = baseURL.appendingPathComponent("v1/library/sync")
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if let token { req.setValue(token, forHTTPHeaderField: "x-kobo-synctoken") }
            let (data, response) = try await http.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw BackendError.serverShapeUnexpected(detail: "not http response")
            }

            let pageEntries = try KoboDecoder.decode([KoboSyncEntry?].self, from: data).compactMap { $0 }
            allEntries.append(contentsOf: pageEntries)

            token = http.value(forHTTPHeaderField: "x-kobo-synctoken") ?? token
            let cont = http.value(forHTTPHeaderField: "x-kobo-sync") ?? ""
            if cont != "continue" { break }
        }
        return KoboLibrarySyncResult(entries: allEntries, nextSyncToken: token)
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KoboClient.librarySync() with pagination loop"
```

---

### Task 3.3: `KoboClient.fetchState()` and `pushState()`

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboClient.swift`
- Modify: `Core/Tests/CoreTests/KoboClientTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@Test func fetchStateReturnsSingleEntry() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.url?.path == "/kobo/TOKEN/v1/library/uuid-1/state")
        let body = #"""
        [{
          "EntitlementId":"uuid-1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
          "StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},
          "Statistics":{"LastModified":"x"},
          "CurrentBookmark":{"LastModified":"x","ProgressPercent":42.0}
        }]
        """#
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body.data(using: .utf8)!)
    }
    let client = KoboClient(baseURL: URL(string: "https://cwa/kobo/TOKEN")!, http: .mocked())
    let state = try await client.fetchState(bookUUID: "uuid-1")
    #expect(state?.currentBookmark?.progressPercent == 42.0)
}

@Test func pushStateSucceeds() async throws {
    MockURLProtocol.handler = { req in
        #expect(req.httpMethod == "PUT")
        #expect(req.url?.path == "/kobo/TOKEN/v1/library/uuid-1/state")
        let bodyData = req.bodyStreamData()
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        #expect(body.contains("\"ProgressPercent\":42"))
        let resp = #"{ "RequestResult": "Success", "UpdateResults": [] }"#
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                resp.data(using: .utf8)!)
    }
    let client = KoboClient(baseURL: URL(string: "https://cwa/kobo/TOKEN")!, http: .mocked())
    let update = KoboStateUpdate(readingStates: [
        .init(currentBookmark: .init(progressPercent: 42, contentSourceProgressPercent: 16, location: nil),
              statusInfo: .init(status: .reading), statistics: nil)
    ])
    try await client.pushState(bookUUID: "uuid-1", update: update)
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

Append to `KoboClient.swift`:

```swift
public extension KoboClient {
    func fetchState(bookUUID: String) async throws -> KoboReadingState? {
        let url = baseURL.appendingPathComponent("v1/library/\(bookUUID)/state")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (data, _) = try await http.data(for: req)
            let states = try KoboDecoder.decode([KoboReadingState].self, from: data)
            return states.first
        } catch HTTPError.notFound {
            return nil
        }
    }

    func pushState(bookUUID: String, update: KoboStateUpdate) async throws {
        let url = baseURL.appendingPathComponent("v1/library/\(bookUUID)/state")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(update)
        _ = try await http.data(for: req)
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KoboClient.fetchState + pushState"
```

---

## Phase 4: KoboProgressMapper

### Task 4.1: Kobo → Readium locator translation

**Files:**
- Create: `Core/Sources/Core/Kobo/KoboProgressMapper.swift`
- Create: `Core/Tests/CoreTests/KoboProgressMapperTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import Core

struct KoboProgressMapperTests {
    @Test func koboToLocatorWithKoboSpan() throws {
        let json = KoboProgressMapper.toLocator(
            source: "f_0035.xhtml",
            type: "KoboSpan",
            value: "kobo.10.1",
            progressPercent: 45.0,
            totalPercent: 16.0
        )
        let dict = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        #expect(dict["href"] as? String == "f_0035.xhtml")
        let locations = dict["locations"] as! [String: Any]
        #expect(locations["progression"] as? Double == 0.45)
        #expect(locations["totalProgression"] as? Double == 0.16)
        #expect(locations["cssSelector"] as? String == #"#kobo\.10\.1"#)
    }

    @Test func koboToLocatorWithoutKoboSpan() throws {
        let json = KoboProgressMapper.toLocator(
            source: "OEBPS/x.xhtml", type: "Generic", value: "",
            progressPercent: 12.0, totalPercent: 6.0
        )
        let dict = try JSONSerialization.jsonObject(with: json.data(using: .utf8)!) as! [String: Any]
        let locations = dict["locations"] as! [String: Any]
        #expect(locations["cssSelector"] == nil)
        #expect(locations["progression"] as? Double == 0.12)
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`Core/Sources/Core/Kobo/KoboProgressMapper.swift`:

```swift
import Foundation

public enum KoboProgressMapper {

    public static func toLocator(
        source: String,
        type: String,
        value: String,
        progressPercent: Double,
        totalPercent: Double
    ) -> String {
        var locations: [String: Any] = [
            "progression": progressPercent / 100.0,
            "totalProgression": totalPercent / 100.0,
        ]
        if value.hasPrefix("kobo.") {
            locations["cssSelector"] = "#" + escapeCSS(value)
        }
        let locator: [String: Any] = [
            "href": source,
            "type": "application/xhtml+xml",
            "locations": locations,
        ]
        let data = try! JSONSerialization.data(withJSONObject: locator)
        return String(data: data, encoding: .utf8)!
    }

    public static func toKoboBookmark(
        href: String,
        koboSpanId: String?,
        progression: Double,
        totalProgression: Double
    ) -> KoboStateUpdate.State.Bookmark {
        let location: KoboLocation? = {
            guard let id = koboSpanId, !id.isEmpty else { return nil }
            return KoboLocation(value: id, type: "KoboSpan", source: href)
        }()
        return .init(
            progressPercent: progression * 100,
            contentSourceProgressPercent: totalProgression * 100,
            location: location
        )
    }

    /// koboSpan IDs only contain `[a-zA-Z0-9.]`, so escaping `.` suffices.
    private static func escapeCSS(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: #"\."#)
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/Core/Kobo/KoboProgressMapper.swift Core/Tests/CoreTests/KoboProgressMapperTests.swift
git commit -m "feat(sync): KoboProgressMapper for Kobo ↔ Readium locator translation"
```

---

### Task 4.2: Readium → Kobo bookmark, no koboSpan

**Files:**
- Modify: `Core/Tests/CoreTests/KoboProgressMapperTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func readiumToKoboWithSpan() {
    let bm = KoboProgressMapper.toKoboBookmark(
        href: "f_0035.xhtml",
        koboSpanId: "kobo.10.1",
        progression: 0.45,
        totalProgression: 0.16
    )
    #expect(bm.progressPercent == 45.0)
    #expect(bm.contentSourceProgressPercent == 16.0)
    #expect(bm.location?.value == "kobo.10.1")
    #expect(bm.location?.source == "f_0035.xhtml")
}

@Test func readiumToKoboWithoutSpan() {
    let bm = KoboProgressMapper.toKoboBookmark(
        href: "f_0035.xhtml", koboSpanId: nil,
        progression: 0.10, totalProgression: 0.05
    )
    #expect(bm.location == nil)
    #expect(bm.progressPercent == 10.0)
}
```

- [ ] **Step 2: Run test, confirm pass**

Already implemented in Task 4.1. Confirming green is the goal here — no impl change needed.

- [ ] **Step 3: Commit if test additions are uncommitted**

```bash
git add -A
git commit -m "test(sync): cover Readium→Kobo bookmark conversion edges"
```

---

## Phase 5: Backend implementations

### Task 5.1: `KOSyncBackend` (wraps existing `KOSyncClient`)

**Files:**
- Create: `Core/Sources/Core/KOSync/KOSyncBackend.swift`
- Create: `Core/Tests/CoreTests/KOSyncBackendTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Core

@MainActor
struct KOSyncBackendTests {
    @Test func fetchProgressMapsToCanonical() async throws {
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/kosync/syncs/progress/abc123")
            let body = #"""
            { "document":"abc123","progress":"5:0.4231","percentage":0.42,
              "device":"Other","device_id":"OTHER","timestamp":1700000000 }
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let kc = KOSyncClient(baseURL: URL(string: "https://cwa/kosync")!, http: .mocked(creds: ("u", "p")))
        let backend = KOSyncBackend(client: kc, deviceID: "DEV", deviceName: "iPhone")
        let id = BookIdentity(partialMD5: "abc123", koboBookUUID: nil)
        let p = try await backend.fetchProgress(for: id)
        #expect(p?.percentage == 0.42)
        #expect(p?.deviceID == "OTHER")
    }

    @Test func fetchProgressMissingIdentityThrows() async throws {
        let kc = KOSyncClient(baseURL: URL(string: "https://cwa/kosync")!, http: .mocked(creds: ("u", "p")))
        let backend = KOSyncBackend(client: kc, deviceID: "DEV", deviceName: "iPhone")
        await #expect(throws: BackendError.identityMissing(field: "partialMD5")) {
            _ = try await backend.fetchProgress(for: BookIdentity(partialMD5: nil, koboBookUUID: nil))
        }
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`Core/Sources/Core/KOSync/KOSyncBackend.swift`:

```swift
import Foundation

public struct KOSyncBackend: SyncBackend {
    public let client: KOSyncClient
    public let deviceID: String
    public let deviceName: String

    public init(client: KOSyncClient, deviceID: String, deviceName: String) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public func authenticate() async throws {
        _ = try await client.authenticate()
    }

    public func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? {
        guard let hash = id.partialMD5 else {
            throw BackendError.identityMissing(field: "partialMD5")
        }
        guard let server = try await client.getProgress(documentHash: hash) else { return nil }
        return CanonicalProgress(
            percentage: server.percentage,
            locatorJSON: nil,    // populated by SyncService using chapter hrefs from Readium
            timestamp: server.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date(),
            deviceID: server.deviceID,
            deviceName: server.device
        )
    }

    public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        guard let hash = id.partialMD5 else {
            throw BackendError.identityMissing(field: "partialMD5")
        }
        // ProgressString constructed by caller and embedded in locatorJSON;
        // here we re-extract the chapter:progression pair for the kosync wire
        // format. Lazy short-cut: caller passes a "<chapter>:<intra>" string
        // in locatorJSON. SyncService.encodeProgress() builds it.
        let progressString = p.locatorJSON ?? "0:0.0000"
        try await client.putProgress(.init(
            document: hash,
            progress: progressString,
            percentage: p.percentage,
            device: deviceName,
            deviceID: deviceID
        ))
    }
}
```

- [ ] **Step 4: Run test, confirm pass**

> Caveat for the engineer: `BackendError.identityMissing(field:)` is an enum
> case, not `Equatable` directly. The Phase 1 spec made the enum `Equatable`
> by hand. If `#expect(throws:)` syntax doesn't accept enum-with-payload
> equality, fall back to a `do { ... } catch BackendError.identityMissing(let f) { #expect(f == "partialMD5") }` pattern.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KOSyncBackend adapter implementing SyncBackend"
```

---

### Task 5.2: `KoboBackend.authenticate` + `fetchProgress`

**Files:**
- Create: `Core/Sources/Core/Kobo/KoboBackend.swift`
- Create: `Core/Tests/CoreTests/KoboBackendTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import Core

@MainActor
struct KoboBackendTests {
    @Test func authenticateHitsInitialization() async throws {
        var hit = false
        MockURLProtocol.handler = { req in
            #expect(req.url?.path.hasSuffix("/v1/initialization") == true)
            hit = true
            let body = #"{ "Resources": { "image_url_template": "x" } }"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let backend = KoboBackend(
            client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: .mocked()),
            deviceID: "D", deviceName: "iPhone"
        )
        try await backend.authenticate()
        #expect(hit)
    }

    @Test func fetchProgressReturnsCanonical() async throws {
        MockURLProtocol.handler = { req in
            let body = #"""
            [{
              "EntitlementId":"u1","Created":"x","LastModified":"2026-05-11T20:00:00Z","PriorityTimestamp":"x",
              "StatusInfo":{"LastModified":"x","Status":"Reading","TimesStartedReading":1},
              "Statistics":{"LastModified":"x"},
              "CurrentBookmark":{"LastModified":"x","ProgressPercent":45.0,"ContentSourceProgressPercent":16.0,
                                 "Location":{"Value":"kobo.10.1","Type":"KoboSpan","Source":"f_0035.xhtml"}}
            }]
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let backend = KoboBackend(
            client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: .mocked()),
            deviceID: "D", deviceName: "iPhone"
        )
        let id = BookIdentity(partialMD5: nil, koboBookUUID: "u1")
        let p = try await backend.fetchProgress(for: id)
        #expect(p?.percentage == 0.16)
        // Server's deviceID is unknown to us; we fill in a marker
        #expect(p?.deviceID == "kobo-peer")
        // Locator JSON contains the cssSelector
        #expect(p?.locatorJSON?.contains(#"#kobo\.10\.1"#) == true)
    }

    @Test func fetchProgressMissingIdentityThrows() async throws {
        let backend = KoboBackend(
            client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: .mocked()),
            deviceID: "D", deviceName: "iPhone"
        )
        await #expect(throws: BackendError.self) {
            _ = try await backend.fetchProgress(for: BookIdentity())
        }
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`Core/Sources/Core/Kobo/KoboBackend.swift`:

```swift
import Foundation

public struct KoboBackend: SyncBackend {
    public let client: KoboClient
    public let deviceID: String
    public let deviceName: String

    public init(client: KoboClient, deviceID: String, deviceName: String) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public func authenticate() async throws {
        _ = try await client.initialization()
    }

    public func fetchProgress(for id: BookIdentity) async throws -> CanonicalProgress? {
        guard let uuid = id.koboBookUUID else {
            throw BackendError.identityMissing(field: "koboBookUUID")
        }
        guard let state = try await client.fetchState(bookUUID: uuid),
              let bookmark = state.currentBookmark else { return nil }
        let percentage = (bookmark.contentSourceProgressPercent ?? 0) / 100.0
        let locatorJSON: String? = bookmark.location.map { loc in
            KoboProgressMapper.toLocator(
                source: loc.source, type: loc.type, value: loc.value,
                progressPercent: bookmark.progressPercent ?? 0,
                totalPercent: bookmark.contentSourceProgressPercent ?? 0
            )
        }
        let timestamp = isoDate(state.lastModified) ?? Date()
        return CanonicalProgress(
            percentage: percentage,
            locatorJSON: locatorJSON,
            timestamp: timestamp,
            deviceID: "kobo-peer",
            deviceName: "Kobo"
        )
    }

    public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
        // Implemented in next task
        fatalError("not implemented")
    }
}

private func isoDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KoboBackend authenticate + fetchProgress"
```

---

### Task 5.3: `KoboBackend.pushProgress`

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboBackend.swift`
- Modify: `Core/Tests/CoreTests/KoboBackendTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func pushProgressSendsExpectedBody() async throws {
    var sentBody: Data?
    MockURLProtocol.handler = { req in
        sentBody = req.bodyStreamData()
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"RequestResult":"Success","UpdateResults":[]}"#.data(using: .utf8)!)
    }
    let backend = KoboBackend(
        client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: .mocked()),
        deviceID: "D", deviceName: "iPhone"
    )
    let id = BookIdentity(partialMD5: nil, koboBookUUID: "u1")
    let locatorJSON = KoboProgressMapper.toLocator(
        source: "f_0035.xhtml", type: "KoboSpan", value: "kobo.10.1",
        progressPercent: 45, totalPercent: 16
    )
    let p = CanonicalProgress(percentage: 0.16, locatorJSON: locatorJSON, timestamp: Date(),
                              deviceID: "D", deviceName: "iPhone")
    try await backend.pushProgress(p, for: id)
    let body = String(data: sentBody ?? Data(), encoding: .utf8) ?? ""
    #expect(body.contains("\"ReadingStates\""))
    #expect(body.contains("\"ProgressPercent\":45"))
    #expect(body.contains("\"Value\":\"kobo.10.1\""))
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement push**

Replace the `fatalError` in `pushProgress`:

```swift
public func pushProgress(_ p: CanonicalProgress, for id: BookIdentity) async throws {
    guard let uuid = id.koboBookUUID else {
        throw BackendError.identityMissing(field: "koboBookUUID")
    }

    // Decode the canonical locator JSON to extract href + koboSpan + intra %.
    // If absent, push percentage-only with no Location.
    let bookmark = try buildBookmark(from: p)
    let update = KoboStateUpdate(readingStates: [
        .init(
            currentBookmark: bookmark,
            statusInfo: .init(status: p.percentage >= 0.99 ? .finished : .reading),
            statistics: nil
        )
    ])
    try await client.pushState(bookUUID: uuid, update: update)
}

private func buildBookmark(from p: CanonicalProgress) throws -> KoboStateUpdate.State.Bookmark {
    let totalProgression = p.percentage
    guard let json = p.locatorJSON,
          let data = json.data(using: .utf8),
          let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .init(progressPercent: totalProgression * 100,
                     contentSourceProgressPercent: totalProgression * 100,
                     location: nil)
    }
    let href = dict["href"] as? String ?? ""
    let locations = dict["locations"] as? [String: Any] ?? [:]
    let progression = locations["progression"] as? Double ?? totalProgression
    let cssSelector = locations["cssSelector"] as? String
    let koboSpan = cssSelector?.hasPrefix("#") == true
        ? String(cssSelector!.dropFirst()).replacingOccurrences(of: #"\."#, with: ".")
        : nil
    return KoboProgressMapper.toKoboBookmark(
        href: href,
        koboSpanId: koboSpan,
        progression: progression,
        totalProgression: totalProgression
    )
}
```

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KoboBackend.pushProgress encodes from canonical locator"
```

---

### Task 5.4: `KoboBackend` as `CatalogBackend`

**Files:**
- Modify: `Core/Sources/Core/Kobo/KoboBackend.swift`
- Modify: `Core/Tests/CoreTests/KoboBackendTests.swift`

- [ ] **Step 1: Write failing test for listLibrary**

```swift
@Test func listLibraryFromSync() async throws {
    var callCount = 0
    MockURLProtocol.handler = { req in
        callCount += 1
        if req.url?.path.hasSuffix("/v1/library/sync") == true {
            let body = #"""
            [{
              "NewEntitlement": {
                "BookEntitlement": {
                  "Id":"u1","CrossRevisionId":"u1","RevisionId":"u1","Accessibility":"Full",
                  "Status":"Active","IsRemoved":false,"Created":"x","LastModified":"x"
                },
                "BookMetadata": {
                  "EntitlementId":"u1","Title":"Test","Contributors":["Author One"],
                  "CoverImageId":"cov1",
                  "DownloadUrls":[{"Format":"KEPUB","Url":"https://cwa/download/1/kepub","Size":100,"Platform":"Generic"}]
                },
                "ReadingState": {
                  "EntitlementId":"u1","Created":"x","LastModified":"x","PriorityTimestamp":"x",
                  "StatusInfo":{"LastModified":"x","Status":"ReadyToRead","TimesStartedReading":0},
                  "Statistics":{"LastModified":"x"},
                  "CurrentBookmark":{"LastModified":"x"}
                }
              }
            }]
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["x-kobo-synctoken": "T", "x-kobo-sync": "None"])!,
                    body.data(using: .utf8)!)
        }
        // Initialization
        let body = #"{ "Resources": { "image_url_template": "https://cwa/{ImageId}/{width}/{height}/false/image.jpg" } }"#
        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body.data(using: .utf8)!)
    }

    let backend = KoboBackend(
        client: KoboClient(baseURL: URL(string: "https://cwa/kobo/T")!, http: .mocked()),
        deviceID: "D", deviceName: "iPhone"
    )
    try await backend.authenticate()       // populates image template
    let entries = try await backend.listLibrary()
    #expect(entries.count == 1)
    #expect(entries[0].title == "Test")
    #expect(entries[0].authors == ["Author One"])
    #expect(entries[0].identity.koboBookUUID == "u1")
    #expect(entries[0].format == .epub)
    #expect(entries[0].downloadURL.absoluteString == "https://cwa/download/1/kepub")
    #expect(entries[0].thumbnailURL?.absoluteString == "https://cwa/cov1/1200/1600/false/image.jpg")
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Add `CatalogBackend` conformance + state**

Modify `KoboBackend.swift`:

```swift
public final class KoboBackend: SyncBackend, CatalogBackend, @unchecked Sendable {
    public let client: KoboClient
    public let deviceID: String
    public let deviceName: String

    private var imageURLTemplate: String?
    private var syncToken: String?

    public init(client: KoboClient, deviceID: String, deviceName: String) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public func authenticate() async throws {
        let res = try await client.initialization()
        self.imageURLTemplate = res.imageURLTemplate
    }

    public func listLibrary() async throws -> [CatalogEntry] {
        if imageURLTemplate == nil {
            try await authenticate()
        }
        let result = try await client.librarySync(syncToken: nil)
        self.syncToken = result.nextSyncToken

        var entries: [CatalogEntry] = []
        for entry in result.entries {
            switch entry {
            case .newEntitlement(let e), .changedEntitlement(let e):
                guard let mapped = mapEntitlement(e) else { continue }
                entries.append(mapped)
            default:
                break
            }
        }
        return entries
    }

    public func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        // CWA's download URLs are direct GETs; nothing to resolve.
        entry.downloadURL
    }

    private func mapEntitlement(_ e: KoboEntitlement) -> CatalogEntry? {
        let bm = e.bookMetadata
        let kepub = bm.downloadUrls.first { $0.format == "KEPUB" }
        let chosen = kepub ?? bm.downloadUrls.first { $0.format == "EPUB" || $0.format == "EPUB3" || $0.format == "EPUB3FL" }
        guard let download = chosen else { return nil }

        let thumb: URL? = {
            guard let template = imageURLTemplate, let coverId = bm.coverImageId else { return nil }
            return URL(string: template
                .replacingOccurrences(of: "{ImageId}", with: coverId)
                .replacingOccurrences(of: "{width}", with: "1200")
                .replacingOccurrences(of: "{height}", with: "1600"))
        }()

        return CatalogEntry(
            serverID: bm.entitlementId,
            title: bm.title,
            authors: bm.contributors,
            identity: BookIdentity(partialMD5: nil, koboBookUUID: bm.entitlementId),
            downloadURL: download.url,
            format: .epub,
            thumbnailURL: thumb
        )
    }
```

(The rest of `pushProgress` and `fetchProgress` is unchanged but stays in this class.)

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): KoboBackend conforms to CatalogBackend (listLibrary)"
```

---

## Phase 6: SwiftData V2

### Task 6.1: Add new fields to `Book`

**Files:**
- Modify: `iOSReader/Models/Book.swift`

- [ ] **Step 1: Add fields**

In `Book.swift`, add three properties:

```swift
var serverIDProtocol: String = "kosync"
var koboBookUUID: String? = nil
var archived: Bool = false
```

Also relax `opdsHref: URL` to `var opdsHref: URL? = nil`. Add `import Core` if not present.

Add computed property:

```swift
var identity: BookIdentity {
    BookIdentity(partialMD5: partialMD5, koboBookUUID: koboBookUUID)
}
```

- [ ] **Step 2: Update initializer**

Add the new params (with defaults) so existing callers compile:

```swift
init(
    id: UUID = UUID(),
    serverID: String,
    serverIDProtocol: String = "kosync",
    title: String,
    authors: [String],
    opdsHref: URL? = nil,
    acquisitionURL: URL,
    format: BookFormat,
    filename: String? = nil,
    partialMD5: String? = nil,
    koboBookUUID: String? = nil,
    thumbnailURL: URL? = nil,
    addedAt: Date = .now,
    archived: Bool = false
) {
    // ... assign all
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -scheme iOSReader -destination "platform=iOS Simulator,name=iPhone 16" build 2>&1 | tail -20
```

Fix any callers passing `opdsHref:` non-optionally — they'll already compile since `URL?` accepts a `URL` literal.

- [ ] **Step 4: Run iOS tests**

```bash
make test-ios
```

Existing tests should pass — the additions are backward-compatible.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): Book model gains serverIDProtocol, koboBookUUID, archived"
```

---

### Task 6.2: Add new fields to `ReadingProgress`

**Files:**
- Modify: `iOSReader/Models/ReadingProgress.swift`

- [ ] **Step 1: Add fields**

```swift
var koboLocationSource: String? = nil
var koboLocationValue: String? = nil
var pendingProtocol: String? = nil
```

Rename `progressString` → `koSyncProgressString` (and make it `String?` if not already).

Add canonical helper:

```swift
var canonical: CanonicalProgress {
    CanonicalProgress(
        percentage: percentage,
        locatorJSON: locatorJSON,
        timestamp: updatedAt,
        deviceID: deviceID,
        deviceName: ""   // filled in by SyncService
    )
}
```

- [ ] **Step 2: Build + test**

```bash
make test-ios 2>&1 | tail -20
```

Fix any callers of `progressString` to use `koSyncProgressString`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(sync): ReadingProgress gains kobo fields + pendingProtocol"
```

---

### Task 6.3: Schema V2 migration plan

**Files:**
- Create: `iOSReader/Models/SchemaV1.swift`
- Create: `iOSReader/Models/SchemaV2.swift`
- Create: `iOSReader/Models/AppMigrationPlan.swift`
- Modify: `iOSReader/App/<wherever ModelContainer is created>.swift`

- [ ] **Step 1: Snapshot V1 schema**

The cleanest path: copy the V1 `Book` and `ReadingProgress` (pre-Task 6.1/6.2) definitions into `SchemaV1.swift` inside `enum SchemaV1: VersionedSchema { ... }`. Set `versionIdentifier = Schema.Version(1, 0, 0)`.

(Engineer: refer to existing iOS Reader repo for any prior schema versioning examples; if none, follow Apple's WWDC23 "Migrate to SwiftData" sample.)

- [ ] **Step 2: Define V2**

`SchemaV2.swift`:

```swift
import SwiftData
import Foundation
import Core

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [Book.self, ReadingProgress.self, Download.self]
}
```

- [ ] **Step 3: Migration plan**

`AppMigrationPlan.swift`:

```swift
import SwiftData

enum AppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [SchemaV1.self, SchemaV2.self]
    static var stages: [MigrationStage] = [
        .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)
    ]
}
```

- [ ] **Step 4: Wire into `ModelContainer`**

Replace the `ModelContainer(for:configurations:)` call with:

```swift
ModelContainer(
    for: Schema(versionedSchema: SchemaV2.self),
    migrationPlan: AppMigrationPlan.self,
    configurations: ModelConfiguration(...)
)
```

- [ ] **Step 5: Build + test**

```bash
make test-ios
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(sync): SwiftData SchemaV2 with migration plan"
```

---

### Task 6.4: One-shot backfill task

**Files:**
- Create: `iOSReader/Services/SchemaBackfill.swift`
- Modify: `iOSReader/App/<RootView or App>.swift`

- [ ] **Step 1: Write failing test**

`iOSReaderTests/SchemaBackfillTests.swift`:

```swift
import Testing
import SwiftData
@testable import iOSReader

@MainActor
struct SchemaBackfillTests {
    @Test func backfillsServerIDProtocolForEmptyString() async throws {
        let container = try ModelContainer(for: Book.self, ReadingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let b = Book(serverID: "x", serverIDProtocol: "", title: "T", authors: [],
                     opdsHref: URL(string: "https://x")!, acquisitionURL: URL(string: "https://x")!,
                     format: .epub)
        ctx.insert(b)
        try ctx.save()

        SchemaBackfill.run(context: ctx)
        #expect(b.serverIDProtocol == "kosync")
    }

    @Test func backfillsPendingProtocol() async throws {
        let container = try ModelContainer(for: Book.self, ReadingProgress.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let rp = ReadingProgress(bookID: UUID(), locatorJSON: nil, koSyncProgressString: "0:0.0",
                                 percentage: 0.5, updatedAt: .now, deviceID: "d",
                                 pendingUpload: true)
        ctx.insert(rp)
        try ctx.save()

        SchemaBackfill.run(context: ctx)
        #expect(rp.pendingProtocol == "kosync")
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`iOSReader/Services/SchemaBackfill.swift`:

```swift
import Foundation
import SwiftData

enum SchemaBackfill {
    static func run(context: ModelContext) {
        let books = (try? context.fetch(FetchDescriptor<Book>(
            predicate: #Predicate { $0.serverIDProtocol == "" }
        ))) ?? []
        for b in books { b.serverIDProtocol = "kosync" }

        let progress = (try? context.fetch(FetchDescriptor<ReadingProgress>(
            predicate: #Predicate { $0.pendingUpload == true && $0.pendingProtocol == nil }
        ))) ?? []
        for p in progress { p.pendingProtocol = "kosync" }

        try? context.save()
    }
}
```

- [ ] **Step 4: Call it from app startup**

Add `SchemaBackfill.run(context: modelContext)` in the `App` struct's `.onAppear` or equivalent first-frame hook.

- [ ] **Step 5: Run tests**

```bash
make test-ios
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(sync): one-shot schema backfill for V2 defaults"
```

---

## Phase 7: Factory + services

### Task 7.1: `AuthStore` gains `activeProtocol`

**Files:**
- Modify: `Core/Sources/Core/AuthStore.swift`

- [ ] **Step 1: Add field**

In `AuthStore`, add:

```swift
public enum SyncProtocol: String, Sendable, Codable {
    case kosync, kobo
}

public var activeProtocol: SyncProtocol = .kosync
public var koboBaseURL: URL? = nil
public var koboImageURLTemplate: String? = nil
```

(Persist via Keychain alongside existing creds. The existing `AuthStore` has a load/save pattern — follow it.)

- [ ] **Step 2: Build + test**

```bash
make test-core
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(sync): AuthStore tracks activeProtocol + Kobo config"
```

---

### Task 7.2: `BackendFactory`

**Files:**
- Create: `iOSReader/Services/BackendFactory.swift`
- Create: `iOSReaderTests/BackendFactoryTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import iOSReader
@testable import Core

@MainActor
struct BackendFactoryTests {
    @Test func buildsKOSyncWhenActive() {
        let auth = AuthStore.testFixture(activeProtocol: .kosync,
                                         baseURL: URL(string: "https://cwa")!,
                                         credentials: ("u","p"))
        let (sync, catalog) = BackendFactory.build(auth: auth, deviceID: "D", deviceName: "iPhone")
        #expect(sync is KOSyncBackend)
        #expect(catalog is OPDSCatalogAdapter)
    }

    @Test func buildsKoboWhenActive() {
        let auth = AuthStore.testFixture(activeProtocol: .kobo,
                                         koboBaseURL: URL(string: "https://cwa/kobo/T")!)
        let (sync, catalog) = BackendFactory.build(auth: auth, deviceID: "D", deviceName: "iPhone")
        #expect(sync is KoboBackend)
        #expect(catalog is KoboBackend)
    }
}
```

- [ ] **Step 2: Run test, confirm fail**

- [ ] **Step 3: Implement**

`iOSReader/Services/BackendFactory.swift`:

```swift
import Foundation
import Core

enum BackendFactory {
    static func build(
        auth: AuthStore,
        deviceID: String,
        deviceName: String
    ) -> (any SyncBackend, any CatalogBackend) {
        switch auth.activeProtocol {
        case .kosync:
            let http = HTTPClient(credentials: auth.credentials)
            let kc = KOSyncClient(baseURL: auth.baseURL!.appendingPathComponent("kosync"), http: http)
            let sync = KOSyncBackend(client: kc, deviceID: deviceID, deviceName: deviceName)
            let catalog = OPDSCatalogAdapter(client: OPDSClient(baseURL: auth.baseURL!, http: http))
            return (sync, catalog)
        case .kobo:
            let http = HTTPClient(credentials: nil)
            let kc = KoboClient(baseURL: auth.koboBaseURL!, http: http)
            let backend = KoboBackend(client: kc, deviceID: deviceID, deviceName: deviceName)
            if let tmpl = auth.koboImageURLTemplate {
                backend.setImageURLTemplate(tmpl)
            }
            return (backend, backend)
        }
    }
}
```

> Note: `OPDSCatalogAdapter` is a thin wrapper exposing the existing `OPDSClient`
> as `CatalogBackend`. Add it in the same task or as 7.2b. Keep the test green by
> stubbing it as a struct that conforms to `CatalogBackend` and delegates the
> two methods.

- [ ] **Step 4: Run test, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(sync): BackendFactory builds active SyncBackend + CatalogBackend"
```

---

### Task 7.3: `OPDSCatalogAdapter`

**Files:**
- Create: `iOSReader/Networking/OPDSCatalogAdapter.swift`
- Create: `iOSReaderTests/OPDSCatalogAdapterTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func adapterMapsOPDSEntriesToCatalog() async throws {
    // Set up MockURLProtocol with a small OPDS feed; assert mapped CatalogEntry
    // has identity.partialMD5 == nil (kosync hashes after download), authors and
    // title populated from OPDS, format from atom link type.
    // ... (test details depend on existing OPDS test fixtures)
}
```

- [ ] **Step 2: Implement adapter**

`iOSReader/Networking/OPDSCatalogAdapter.swift`:

```swift
import Foundation
import Core

struct OPDSCatalogAdapter: CatalogBackend {
    let client: OPDSClient

    func listLibrary() async throws -> [CatalogEntry] {
        let feed = try await client.fetchRoot()  // exact method name per existing client
        return feed.entries.map { e in
            CatalogEntry(
                serverID: e.atomID,
                title: e.title,
                authors: e.authors,
                identity: BookIdentity(partialMD5: nil, koboBookUUID: nil),
                downloadURL: e.acquisitionURL,
                format: e.format,
                thumbnailURL: e.thumbnailURL
            )
        }
    }

    func resolveDownload(for entry: CatalogEntry) async throws -> URL {
        entry.downloadURL
    }
}
```

(Engineer: adapt method/field names to match the live `OPDSClient` API.)

- [ ] **Step 3: Run iOS tests**

```bash
make test-ios
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(sync): OPDS catalog adapter conforms to CatalogBackend"
```

---

### Task 7.4: Refactor `SyncService` to use `SyncBackend` + protocol pinning

**Files:**
- Modify: `iOSReader/Services/SyncService.swift`
- Modify: `iOSReaderTests/SyncServiceTests.swift`

- [ ] **Step 1: Write failing test for protocol pinning**

```swift
@Test func bufferThenSwitchProtocolStillFlushesToOriginalBackend() async throws {
    // Stub kosync + kobo backends with a recording mock for both.
    // Buffer a write under kosync (sets pendingProtocol = "kosync").
    // Swap factory output to kobo backend.
    // Call flushAllPending; assert the kosync backend received the push, not kobo.
}
```

- [ ] **Step 2: Implement the refactor**

Replace constructor and the existing methods:

```swift
@MainActor
final class SyncService {
    private let backendForProtocol: (AuthStore.SyncProtocol) -> any SyncBackend
    private let context: ModelContext
    let deviceID: String
    let deviceName: String
    let activeProtocol: AuthStore.SyncProtocol

    init(
        backendForProtocol: @escaping (AuthStore.SyncProtocol) -> any SyncBackend,
        context: ModelContext,
        activeProtocol: AuthStore.SyncProtocol,
        deviceID: String,
        deviceName: String
    ) {
        self.backendForProtocol = backendForProtocol
        self.context = context
        self.activeProtocol = activeProtocol
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    func onOpen(book: Book) async throws -> OnOpenAction { /* identical logic, calls backendForProtocol(activeProtocol) */ }

    func bufferLocator(book: Book, locatorJSON: String, percentage: Double) {
        // store locatorJSON + percentage, set pendingProtocol = activeProtocol.rawValue
    }

    func flushPendingProgress(for book: Book) async {
        guard let row = currentLocalProgress(for: book.id),
              row.pendingUpload,
              let pinned = row.pendingProtocol,
              let proto = AuthStore.SyncProtocol(rawValue: pinned) else { return }
        let backend = backendForProtocol(proto)
        do {
            try await backend.pushProgress(row.canonical, for: book.identity)
            row.pendingUpload = false
            try? context.save()
        } catch {
            // leave for retry
        }
    }
}
```

- [ ] **Step 3: Run tests, confirm pass**

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(sync): SyncService routes via SyncBackend with protocol pinning"
```

---

## Phase 8: Library mode-switch

### Task 8.1: `LibraryService.refresh` via active `CatalogBackend`

**Files:**
- Modify: `iOSReader/Services/LibraryService.swift`
- Modify: `iOSReaderTests/LibraryServiceTests.swift`

- [ ] **Step 1: Write failing test**

```swift
@Test func refreshUpsertsBooksByMatchingTitleAuthors() async throws {
    // Given: a Book row from old protocol (kosync, partialMD5 set, no kobo UUID)
    // When: refresh() runs with a Kobo CatalogBackend returning a same-titled book with koboBookUUID set
    // Then: existing Book gets koboBookUUID populated; no duplicate inserted.
}

@Test func refreshArchivesMissingBooks() async throws {
    // Given: a Book exists locally, not in new catalog response.
    // When: refresh() with the new catalog.
    // Then: book.archived == true.
}
```

- [ ] **Step 2: Implement**

```swift
func refresh(using catalog: any CatalogBackend) async throws {
    let entries = try await catalog.listLibrary()
    let existing = try context.fetch(FetchDescriptor<Book>())
    var matchedIDs: Set<UUID> = []

    for entry in entries {
        if let book = matchBook(in: existing, to: entry) {
            // Populate missing identity fields without overwriting
            if entry.identity.partialMD5 != nil && book.partialMD5 == nil {
                book.partialMD5 = entry.identity.partialMD5
            }
            if entry.identity.koboBookUUID != nil && book.koboBookUUID == nil {
                book.koboBookUUID = entry.identity.koboBookUUID
            }
            book.archived = false
            matchedIDs.insert(book.id)
        } else {
            let new = Book(
                serverID: entry.serverID,
                serverIDProtocol: ...,   // from caller's active protocol
                title: entry.title,
                authors: entry.authors,
                opdsHref: nil,
                acquisitionURL: entry.downloadURL,
                format: entry.format,
                partialMD5: entry.identity.partialMD5,
                koboBookUUID: entry.identity.koboBookUUID,
                thumbnailURL: entry.thumbnailURL
            )
            context.insert(new)
            matchedIDs.insert(new.id)
        }
    }

    for book in existing where !matchedIDs.contains(book.id) {
        book.archived = true
    }
    try context.save()
}

private func matchBook(in existing: [Book], to entry: CatalogEntry) -> Book? {
    // Exact identity hit first
    if let uuid = entry.identity.koboBookUUID,
       let m = existing.first(where: { $0.koboBookUUID == uuid }) { return m }
    if let hash = entry.identity.partialMD5,
       let m = existing.first(where: { $0.partialMD5 == hash }) { return m }
    // Fall back to normalized title+authors
    let tn = normalize(entry.title)
    let an = entry.authors.map(normalize).sorted()
    return existing.first { book in
        normalize(book.title) == tn &&
        book.authors.map(normalize).sorted() == an
    }
}

private func normalize(_ s: String) -> String {
    s.lowercased().filter { !$0.isPunctuation && !$0.isWhitespace }
}
```

- [ ] **Step 3: Run tests, confirm pass**

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(sync): LibraryService.refresh matches across protocols"
```

---

## Phase 9: Settings UI

### Task 9.1: Settings protocol picker

**Files:**
- Modify: `iOSReader/UI/Settings/SettingsView.swift` (or equivalent)

- [ ] **Step 1: Update the form**

Add a `Picker("Protocol", selection: $vm.activeProtocol)` with two cases. Conditionally render the kosync fields (URL/user/password) or Kobo field (URL only) based on selection.

```swift
Section("Server") {
    Picker("Protocol", selection: $vm.activeProtocol) {
        Text("KOReader Sync").tag(AuthStore.SyncProtocol.kosync)
        Text("Kobo").tag(AuthStore.SyncProtocol.kobo)
    }
    switch vm.activeProtocol {
    case .kosync:
        TextField("Server URL", text: $vm.baseURLString)
        TextField("Username", text: $vm.username)
        SecureField("Password", text: $vm.password)
    case .kobo:
        TextField("Sync URL (paste from CWA)", text: $vm.koboBaseURLString)
        Text("Get this from CWA admin → enable Kobo sync.")
            .font(.caption).foregroundStyle(.secondary)
    }
    Button("Test connection") { Task { await vm.testConnection() } }
}
```

- [ ] **Step 2: Wire `testConnection()` in the view model**

```swift
func testConnection() async {
    do {
        let auth = drafToAuth()
        let (sync, _) = BackendFactory.build(auth: auth, deviceID: "test", deviceName: "test")
        try await sync.authenticate()
        // For Kobo also verify the init response shape:
        if auth.activeProtocol == .kobo, let backend = sync as? KoboBackend {
            // KoboBackend.authenticate already calls /v1/initialization;
            // shape failure raises serverShapeUnexpected
            _ = backend
        }
        connectionStatus = .ok
        persist(auth)
    } catch {
        connectionStatus = .error("\(error)")
    }
}
```

- [ ] **Step 3: Build + run sim**

```bash
xcodegen generate
xcodebuild -scheme iOSReader -destination "platform=iOS Simulator,name=iPhone 16" build 2>&1 | tail -5
```

Smoke-test in the simulator: open Settings, flip the picker, observe field changes.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(sync): Settings protocol picker + Test connection"
```

---

### Task 9.2: Protocol switch confirmation + library refresh

**Files:**
- Modify: `iOSReader/UI/Settings/SettingsView.swift`
- Modify: `iOSReader/Services/LibraryService.swift`

- [ ] **Step 1: Detect protocol change**

In the view model, when `activeProtocol` changes via the picker, show a `.confirmationDialog` before persisting the change.

- [ ] **Step 2: On confirm**

```swift
func confirmProtocolSwitch() async {
    persist(auth.with(activeProtocol: pickerSelection))
    await refreshLibrary()
}
```

- [ ] **Step 3: Smoke-test in simulator**

Switch kosync → Kobo, observe library refresh banner, observe books appearing.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(sync): protocol switch confirmation triggers library refresh"
```

---

## Phase 10: Docs + manual smoke

### Task 10.1: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Sync protocols" section**

Document both modes, when to pick which, and the v1 known limitations. Reference the spec file.

- [ ] **Step 2: Move CWA-Automated requirement note**

Soften from "only CWA" to "CWA for either protocol; vanilla calibre-web only via kosync sidecar."

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(sync): document protocol picker + Kobo mode setup"
```

---

### Task 10.2: Manual smoke test checklist

**Files:**
- Modify: `docs/superpowers/plans/2026-05-11-multi-protocol-sync.md` (this file — add results section)

- [ ] **Step 1: Run smoke test 1 — fresh kosync install**

Fresh sim install → kosync mode → CWA creds → library populates → download → read → progress visible in `kosync_progress`.

Verify on cluster:

```bash
kubectl exec -n calibre-web deploy/calibre-web -- \
  sqlite3 /config/app.db \
  "SELECT document, percentage, device FROM kosync_progress ORDER BY timestamp DESC LIMIT 5;"
```

- [ ] **Step 2: Run smoke test 2 — fresh Kobo install**

Fresh sim install → Kobo mode → paste token URL → library populates (KEPUB downloads) → read → progress visible in `kobo_reading_state` + `kobo_bookmark`.

```bash
kubectl exec -n calibre-web deploy/calibre-web -- \
  sqlite3 /config/app.db \
  "SELECT krs.book_id, kb.progress_percent, kb.location_value
   FROM kobo_bookmark kb JOIN kobo_reading_state krs ON kb.kobo_reading_state_id = krs.id
   ORDER BY kb.last_modified DESC LIMIT 5;"
```

- [ ] **Step 3: Run smoke test 3 — migration from V1**

Install on an existing simulator that has SchemaV1 data → V1→V2 migration runs → switch to Kobo mode → library refreshes → existing books match by title, get koboBookUUID populated.

- [ ] **Step 4: Run smoke test 4 — real Kobo ↔ iPhone**

Read 10% into a book on the real Kobo. Open same book on iPhone in Kobo mode. Verify "Continue from another device?" prompt with the right percentage. Accept; reader lands within 1 sentence (KEPUB) or ~2% (plain EPUB).

- [ ] **Step 5: Run smoke test 5 — protocol pinning**

In kosync mode, read a page (buffers a write). Without backgrounding, open Settings, switch to Kobo. Wait 30s. Check kosync DB row updated, kobo DB row unchanged for that book.

- [ ] **Step 6: Add results section to this file**

Append a "Smoke test results 2026-05-XX" section listing pass/fail per item.

- [ ] **Step 7: Commit results**

```bash
git add docs/superpowers/plans/2026-05-11-multi-protocol-sync.md
git commit -m "docs(sync): record smoke test results for multi-protocol sync"
```

---

## Smoke test checklist (Task 10.2 execution)

> **Prepared 2026-05-12 by assistant — execution pending.** The "no backwards compatibility" decision dropped Tasks 6.3/6.4 (SchemaV1 snapshot + AppMigrationPlan + SchemaBackfill); smoke test #3 (V1→V2 migration) is therefore **N/A** for this build. Run the remaining four scenarios and record pass/fail + observations inline below each block.

### Pre-flight

- [ ] Branch `feat/v1` at HEAD `a702f49` (or descendant). Verify with `git log -1 --oneline`.
- [ ] `make test-core` → **91 tests** passing.
- [ ] `make test-ios` → **82 tests** passing.
- [ ] Simulator: iPhone 17 (or whatever's available; iPhone 16 not installed locally). Erase any prior install with stale SwiftData store: `xcrun simctl erase <UDID>` — the BC waiver means there's no in-place migration from a Phase-5-era schema.
- [ ] CWA reachable: `curl -fsS https://cwa.example.com/opds/` should return XML.
- [ ] Kobo token retrievable from cluster:
      ```bash
      kubectl exec -n calibre-web deploy/calibre-web -- \
        sqlite3 /config/app.db \
        "SELECT auth_token FROM remote_auth_token WHERE token_type=1 LIMIT 1;"
      ```
      The Kobo sync URL is `https://cwa.example.com/kobo/<TOKEN>/`.

### Smoke 1 — fresh kosync install

1. Erase simulator → install app fresh.
2. Settings → protocol picker `KOReader Sync` → enter `https://cwa.example.com` + CWA username + password.
3. Tap **Test & Save**. Expect green "Connected".
4. Library should populate from `/opds/`. Confirm cover thumbnails render.
5. Tap a book → it downloads → tap again to open in reader.
6. Page through 3-4 pages.
7. Cluster check — `progress` should appear server-side:
   ```bash
   kubectl exec -n calibre-web deploy/calibre-web -- \
     sqlite3 /config/app.db \
     "SELECT document, percentage, device FROM kosync_progress ORDER BY timestamp DESC LIMIT 5;"
   ```
   Expect a row matching the book's partialMD5 with the device name = `UIDevice.current.name`. The `progress` column should look like `"0:0.XXXX"` (Task 7.5 wire-format fix — chapter pinned to 0, intra from Readium locator).

- [ ] **Pass** / [ ] **Fail** — Notes: _________________

### Smoke 2 — fresh Kobo install

1. Erase simulator → install app fresh.
2. Settings → protocol picker `Kobo Sync` → paste `https://cwa.example.com/kobo/<TOKEN>/` (no username/password).
3. Tap **Test & Save**. Expect green "Connected".
4. Library should populate (KEPUB books appear with metadata).
5. **Known v1 limitation**: KEPUB isn't readable in the app's reader. Verify the library list renders books with covers + titles + authors; tapping a book should fail gracefully (or fallback to download → opener TBD).
6. Cluster check — Kobo state should appear server-side:
   ```bash
   kubectl exec -n calibre-web deploy/calibre-web -- \
     sqlite3 /config/app.db \
     "SELECT krs.book_id, kb.progress_percent, kb.location_value
      FROM kobo_bookmark kb JOIN kobo_reading_state krs ON kb.kobo_reading_state_id = krs.id
      ORDER BY kb.last_modified DESC LIMIT 5;"
   ```
   For this test, expect **no rows** initially (the app can't push Kobo progress yet without a working KEPUB reader). The catalog-fetch alone is the verification target.

- [ ] **Pass** / [ ] **Fail** — Notes: _________________

### Smoke 3 — V1 → V2 migration

**N/A.** Skipped per the "no backwards compatibility" decision early in Phase 6. The schema mechanically requires erasing the existing simulator install before first launch on the V2 schema; there is no in-place migration path from Phase-5 data.

### Smoke 4 — real Kobo ↔ iPhone

**Hardware-gated.** Requires a physical Kobo e-reader paired to the same CWA. The 1% precision claim ("within 1 sentence (KEPUB) or ~2% (plain EPUB)") needs a real Kobo to validate.

If a physical Kobo is unavailable, this test is deferred to a follow-up session.

1. On the real Kobo, read 10% into a book via the Kobo's own native reader (NOT KOReader).
2. Wait for the Kobo to sync with CWA (usually triggered by a sleep/wake or manual sync).
3. Open the same book on iPhone in this app, Kobo Sync mode.
4. Expect a "Continue from another device?" prompt with the right percentage (~10%).
5. Accept; reader should land within 1 sentence (if KEPUB) or ~2% (if plain EPUB).

- [ ] **Pass** / [ ] **Fail** / [ ] **Deferred — no hardware** — Notes: _________________

### Smoke 5 — protocol pinning

This is the load-bearing guarantee from Task 7.4. Verify the protocol-switch UX preserves in-flight writes via the original backend.

1. In kosync mode (Smoke 1 state), open a book and page through 2-3 pages — this buffers a write under kosync.
2. **Without backgrounding**, navigate to Settings → switch picker to Kobo Sync → paste the kobo URL.
3. Tap Test & Save. The confirmation dialog should appear ("Switch to Kobo Sync?"). Accept.
4. Wait 30 seconds (background flush trigger).
5. Cluster check — kosync row for the book should be **updated** (the buffered write flushed via the pinned kosync backend, NOT misrouted to Kobo):
   ```bash
   kubectl exec -n calibre-web deploy/calibre-web -- \
     sqlite3 /config/app.db \
     "SELECT document, percentage, device, timestamp FROM kosync_progress ORDER BY timestamp DESC LIMIT 3;"
   ```
6. Cross-check — kobo state for the same book should be **unchanged** (or absent) since the pinned protocol was kosync:
   ```bash
   kubectl exec -n calibre-web deploy/calibre-web -- \
     sqlite3 /config/app.db \
     "SELECT book_id, last_modified FROM kobo_reading_state ORDER BY last_modified DESC LIMIT 3;"
   ```

- [ ] **Pass** / [ ] **Fail** — Notes: _________________

### Wrap-up

After smoke tests:

- [ ] Append a `## Smoke test results 2026-05-XX` section here with concrete pass/fail per item + any anomalies observed.
- [ ] If anything failed, file follow-up issues; do NOT amend prior commits — record gaps as separate fixes.
- [ ] If all green, commit:
      ```bash
      git add docs/superpowers/plans/2026-05-11-multi-protocol-sync.md
      git commit -m "docs(sync): record smoke test results for multi-protocol sync"
      ```

---

## Self-review notes

- Spec coverage: Phase 1–5 cover the protocol abstraction and Kobo wire types (spec §Architecture + §Kobo Client surface). Phase 6 covers SwiftData V2 + migrations (spec §SwiftData model changes). Phase 7 covers BackendFactory and SyncService refactor (spec §Conflict resolution, §protocol pinning). Phase 8 covers mode-switch matching (spec §Mode-switch matching). Phase 9 covers Settings UX (spec §Settings UX). Phase 10 covers docs + smoke (spec §Testing strategy layer 3).
- Non-goals (spec §Non-goals): shelves, annotations, statistics, OAuth, store proxy, real-time sync, multi-server, auto-detect, mid-flight conversion, library deletion. None of these have tasks. Confirmed deferred.
- Type consistency: `CanonicalProgress`, `BookIdentity`, `BackendError`, `KoboReadingState`, `KoboCurrentBookmark`, `KoboLocation`, `KoboBookmarkPayload` (renamed `KoboStateUpdate.State.Bookmark` in implementation), `KoboSyncEntry`, `KoboEntitlement`, `KoboBookMetadata`, `KoboDownloadURL`, `KoboInitResources`, `KoboLibrarySyncResult`, `KoboStateUpdate`, `KOSyncBackend`, `KoboBackend`, `OPDSCatalogAdapter`, `BackendFactory`, `SchemaBackfill`, `SchemaV1`, `SchemaV2`, `AppMigrationPlan` — all referenced consistently across tasks.
- Outstanding caveats:
  - `Optional: Decodable` extension in Task 2.3 may not compile in all toolchain versions; fallback is a wrapper newtype `KoboSyncEntryOrSkip`. Mentioned inline.
  - `KoboBackend` switched from `struct` to `final class` in Task 5.4 to carry mutable state (`imageURLTemplate`, `syncToken`). Earlier tasks (5.2, 5.3) wrote `struct` — engineer should treat the Task 5.4 form as authoritative and harmonize if needed during Task 5.4.
