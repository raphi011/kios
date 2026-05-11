# Reader View Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the pushed `ReaderView` with an immersive `fullScreenCover` modal that supports edge-tap page turns, pinch-to-resize font, hardware keys (`←` / `→` / `ESC`), swipe-down dismiss, and tap-to-reveal chrome.

**Architecture:** Hybrid layering. UIKit owns input (gesture recognizers on the container VC's view + `UIKeyCommand`s) so it coexists cleanly with Readium's existing recognizers. SwiftUI owns chrome (top bar, bottom progress strip, font HUD) driven by a single `@State var uiVisible` flag in `ReaderView`. Font size is the only piece of persistent state we add (`@AppStorage`).

**Tech Stack:** Swift 5.10, SwiftUI iOS 17+, SwiftData, UIKit (for the navigator wrapper and input recognizers), Readium 3.8 (`ReadiumNavigator.EPUBNavigatorViewController`), Swift Testing (`@Suite`, `@Test`).

**Spec:** `docs/superpowers/specs/2026-05-11-reader-view-improvements-design.md`

---

## File map

### Created

| Path | Responsibility |
|---|---|
| `iOSReader/Views/Reader/ReaderGestureHelpers.swift` | Pure functions for tap classification, font-size stepping, and swipe-dismiss policy. No UIKit / SwiftUI deps; fully unit-testable. |
| `iOSReader/Views/Reader/ReaderRoute.swift` | `Identifiable` wrapper around `UUID` for `fullScreenCover(item:)`. |
| `iOSReader/Views/Reader/ReaderInputHandlers.swift` | Owns the tap + pinch recognizers; attaches to a host `UIView`; exposes callbacks for left/center/right tap and pinch update/commit. |
| `iOSReader/Views/Reader/ReaderContainerVC.swift` | UIKit container hosting `EPUBNavigatorViewController` as a child; owns `ReaderInputHandlers`; declares `UIKeyCommand`s; applies `EPUBPreferences` on font-size changes; manages status-bar appearance. |
| `iOSReader/Views/Reader/ReaderChrome.swift` | SwiftUI views: `ReaderTopBar`, `ReaderBottomProgressBar`, `ReaderFontHUD`. |
| `iOSReaderTests/Views/Reader/TapZoneClassifierTests.swift` | Unit tests for tap zone boundaries. |
| `iOSReaderTests/Views/Reader/FontSizeStepTests.swift` | Unit tests for pinch-scale → font-percent stepping. |
| `iOSReaderTests/Views/Reader/SwipeDismissPolicyTests.swift` | Unit tests for swipe-down dismissal criteria. |

### Modified

| Path | Change |
|---|---|
| `iOSReader/Views/ReaderView.swift` → `iOSReader/Views/Reader/ReaderView.swift` | Refactored: holds `uiVisible`, `fontHUD`, `currentLocator`, `@AppStorage("reader.fontSizePct")`; composes `ReaderHost` with the chrome overlay; carries swipe-down dismiss gesture. `ReaderHost` extracted into its own file. |
| `iOSReader/Views/Reader/ReaderHost.swift` (split out of the old `ReaderView.swift`) | Now wraps `ReaderContainerVC` (was wrapping `EPUBNavigatorViewController` directly). Passes `fontSizePct` and input callbacks through. |
| `iOSReader/App/AppEnvironment.swift` | Add `activeReader: ReaderRoute?` and `openReader(_:)` method. |
| `iOSReader/Views/RootView.swift` | Attach `.fullScreenCover(item: $env.activeReader)` above `TabView`. |
| `iOSReader/Views/HomeRootView.swift` | Replace `NavigationLink { ReaderView }` with `Button { env.openReader(book.id) }`. |
| `iOSReader/Views/FeedView.swift` | Replace `path.append(OpenReaderRoute(...))` with `env.openReader(...)`. |
| `iOSReader/Views/BrowseRootView.swift` | Remove `navigationDestination(for: OpenReaderRoute.self)` block and the `OpenReaderRoute` struct itself. |
| `iOSReader/Views/BookDetailView.swift` | Replace `NavigationLink("Open") { ReaderView(...) }` with `Button("Open") { env.openReader(...) }`. |

---

## Cross-cutting build / test commands

Use these throughout the plan. `iPhone 16` is the canonical test simulator (any installed iOS 17+ sim works; substitute if absent).

**Build:**
```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

**Run unit tests:**
```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

**Run a single test class:**
```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/TapZoneClassifierTests
```

**Adding new files to the Xcode target:** this project uses XcodeGen — `project.yml` is the source of truth and `iOSReader.xcodeproj/` is gitignored / regenerated. Any `.swift` file placed under `iOSReader/` (app target) or `iOSReaderTests/` (test target) is auto-picked up by `xcodegen generate`. After creating a new file:

```bash
xcodegen generate
```

That's it — no Xcode UI, no pbxproj edits, no commit of `project.pbxproj` (it's gitignored).

After every "Add file" step, run `xcodegen generate` then the build command to confirm the file compiles.

---

## Task 1: Tap zone classifier (TDD)

**Files:**
- Create: `iOSReader/Views/Reader/ReaderGestureHelpers.swift`
- Test: `iOSReaderTests/Views/Reader/TapZoneClassifierTests.swift`

Creates the first of three pure helper functions and seeds the `Reader/` directory.

- [ ] **Step 1: Create directories**

```bash
mkdir -p iOSReader/Views/Reader
mkdir -p iOSReaderTests/Views/Reader
```

- [ ] **Step 2: Write the failing test**

Create `iOSReaderTests/Views/Reader/TapZoneClassifierTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import iOSReader

@Suite("TapZoneClassifier")
struct TapZoneClassifierTests {

    @Test func classifiesLeftEdge() {
        #expect(TapZoneClassifier.classify(x: 0, width: 400) == .left)
        #expect(TapZoneClassifier.classify(x: 99, width: 400) == .left)
    }

    @Test func classifiesRightEdge() {
        #expect(TapZoneClassifier.classify(x: 301, width: 400) == .right)
        #expect(TapZoneClassifier.classify(x: 400, width: 400) == .right)
    }

    @Test func classifiesCenter() {
        #expect(TapZoneClassifier.classify(x: 100, width: 400) == .center)
        #expect(TapZoneClassifier.classify(x: 200, width: 400) == .center)
        #expect(TapZoneClassifier.classify(x: 300, width: 400) == .center)
    }

    @Test func handlesZeroWidth() {
        // Degenerate case during layout; should not crash and should not turn pages.
        #expect(TapZoneClassifier.classify(x: 0, width: 0) == .center)
    }
}
```

- [ ] **Step 3: Add test file to the Xcode test target**

Open Xcode → right-click `iOSReaderTests/Views/` group → **Add Files to "iOSReader"…**, select `Views/Reader/TapZoneClassifierTests.swift`, confirm the **iOSReaderTests** target is the only one checked.

- [ ] **Step 4: Run test, confirm it fails**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/TapZoneClassifierTests
```
Expected: build failure — `cannot find 'TapZoneClassifier' in scope`.

- [ ] **Step 5: Write minimal implementation**

Create `iOSReader/Views/Reader/ReaderGestureHelpers.swift`:

```swift
import CoreGraphics

enum TapZone {
    case left, center, right
}

/// Classifies a tap location into a 25 % / 50 % / 25 % zone.
enum TapZoneClassifier {
    static func classify(x: CGFloat, width: CGFloat) -> TapZone {
        guard width > 0 else { return .center }
        let ratio = x / width
        if ratio < 0.25 { return .left }
        if ratio > 0.75 { return .right }
        return .center
    }
}
```

- [ ] **Step 6: Add source file to the Xcode app target**

In Xcode → right-click `iOSReader/Views/` group → **Add Files to "iOSReader"…**, select `Views/Reader/ReaderGestureHelpers.swift`, confirm only the **iOSReader** target is checked.

- [ ] **Step 7: Run test, confirm it passes**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/TapZoneClassifierTests
```
Expected: `Test Suite 'All tests' passed` — 4 tests passed.

- [ ] **Step 8: Commit**

```bash
git add iOSReader/Views/Reader/ReaderGestureHelpers.swift \
        iOSReaderTests/Views/Reader/TapZoneClassifierTests.swift \
git commit -m "feat(reader): add TapZoneClassifier helper"
```

---

## Task 2: Font size stepping (TDD)

**Files:**
- Modify: `iOSReader/Views/Reader/ReaderGestureHelpers.swift`
- Test: `iOSReaderTests/Views/Reader/FontSizeStepTests.swift`

- [ ] **Step 1: Write the failing test**

Create `iOSReaderTests/Views/Reader/FontSizeStepTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import iOSReader

@Suite("FontSizeStep")
struct FontSizeStepTests {

    @Test func identityWhenScaleIsOne() {
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.0) == 100)
        #expect(FontSizeStep.clamp(startPct: 130, scale: 1.0) == 130)
    }

    @Test func stepsUpInTensOnScaleAbove() {
        // 100 × 1.15 = 115 → rounds to 120 (nearest 10).
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.15) == 120)
        // 100 × 1.05 = 105 → rounds to 110.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.05) == 110)
    }

    @Test func stepsDownInTensOnScaleBelow() {
        // 100 × 0.85 = 85 → rounds to 90.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 0.85) == 90)
    }

    @Test func clampsToMin() {
        // 100 × 0.1 = 10 → clamps to 60.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 0.1) == 60)
        #expect(FontSizeStep.clamp(startPct: 60, scale: 0.5) == 60)
    }

    @Test func clampsToMax() {
        // 100 × 5 = 500 → clamps to 200.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 5.0) == 200)
        #expect(FontSizeStep.clamp(startPct: 200, scale: 1.5) == 200)
    }

    @Test func roundsAtHalfStepBoundary() {
        // 100 × 1.05 = 105 → exactly halfway between 100 and 110.
        // Banker's rounding would yield 100; we want consistent "round up at .5" → 110.
        #expect(FontSizeStep.clamp(startPct: 100, scale: 1.05) == 110)
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode test target**

In Xcode → right-click `iOSReaderTests/Views/Reader/` group → **Add Files to "iOSReader"…**, select `FontSizeStepTests.swift`, confirm only **iOSReaderTests** is checked.

- [ ] **Step 3: Run, confirm failure**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/FontSizeStepTests
```
Expected: `cannot find 'FontSizeStep' in scope`.

- [ ] **Step 4: Append to `ReaderGestureHelpers.swift`**

Append to `iOSReader/Views/Reader/ReaderGestureHelpers.swift`:

```swift
/// Maps a pinch scale onto a clamped, 10-step font-size percent.
enum FontSizeStep {
    static let min: Int = 60
    static let max: Int = 200
    static let step: Int = 10

    /// `startPct` is the font size at gesture begin; `scale` is the
    /// pinch recogniser's cumulative scale. Output is snapped to the
    /// nearest multiple of `step` within `[min, max]`.
    static func clamp(startPct: Int, scale: CGFloat) -> Int {
        let raw = Double(startPct) * Double(scale)
        // .toNearestOrAwayFromZero rounds 105.0 → 110.0 deterministically
        // (.toNearestOrEven would give 100 — bad UX, "halfway never moves").
        let stepped = (raw / Double(step)).rounded(.toNearestOrAwayFromZero) * Double(step)
        let bounded = Swift.max(Double(min), Swift.min(Double(max), stepped))
        return Int(bounded)
    }
}
```

- [ ] **Step 5: Run, confirm pass**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/FontSizeStepTests
```
Expected: 6 tests passed.

- [ ] **Step 6: Commit**

```bash
git add iOSReader/Views/Reader/ReaderGestureHelpers.swift \
        iOSReaderTests/Views/Reader/FontSizeStepTests.swift \
git commit -m "feat(reader): add FontSizeStep helper"
```

---

## Task 3: Swipe-down dismiss policy (TDD)

**Files:**
- Modify: `iOSReader/Views/Reader/ReaderGestureHelpers.swift`
- Test: `iOSReaderTests/Views/Reader/SwipeDismissPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `iOSReaderTests/Views/Reader/SwipeDismissPolicyTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import iOSReader

@Suite("SwipeDismissPolicy")
struct SwipeDismissPolicyTests {

    @Test func dismissesOnLargeDownwardVerticalDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 10, height: 200),
            velocity: CGSize(width: 0, height: 800)
        )
        #expect(result == true)
    }

    @Test func rejectsShortDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: 50),
            velocity: CGSize(width: 0, height: 800)
        )
        #expect(result == false)
    }

    @Test func rejectsUpwardDrag() {
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: -200),
            velocity: CGSize(width: 0, height: -800)
        )
        #expect(result == false)
    }

    @Test func rejectsHorizontalDominantDrag() {
        // dx = 200, dy = 150 → |dx| > |dy|, should be a horizontal drag.
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 200, height: 150),
            velocity: CGSize(width: 600, height: 400)
        )
        #expect(result == false)
    }

    @Test func rejectsZeroVelocityEvenIfDistanceMet() {
        // A drag that ended stationary — user is hesitating, not dismissing.
        let result = SwipeDismissPolicy.shouldDismiss(
            translation: CGSize(width: 0, height: 200),
            velocity: CGSize(width: 0, height: 0)
        )
        #expect(result == false)
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode test target**

In Xcode → right-click `iOSReaderTests/Views/Reader/` → **Add Files…**, select `SwipeDismissPolicyTests.swift`, target = **iOSReaderTests** only.

- [ ] **Step 3: Run, confirm failure**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/SwipeDismissPolicyTests
```
Expected: `cannot find 'SwipeDismissPolicy' in scope`.

- [ ] **Step 4: Append to `ReaderGestureHelpers.swift`**

Append to `iOSReader/Views/Reader/ReaderGestureHelpers.swift`:

```swift
/// Decides whether a drag-down gesture should dismiss the reader.
enum SwipeDismissPolicy {
    static let minDistance: CGFloat = 120
    static let dominanceRatio: CGFloat = 1.5

    static func shouldDismiss(translation: CGSize, velocity: CGSize) -> Bool {
        // Must be a downward drag past the threshold.
        guard translation.height > minDistance else { return false }
        // Must end with downward velocity (excludes hesitations and reversals).
        guard velocity.height > 0 else { return false }
        // Must be vertically dominant (excludes diagonal scrolls).
        return abs(translation.height) > dominanceRatio * abs(translation.width)
    }
}
```

- [ ] **Step 5: Run, confirm pass**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:iOSReaderTests/SwipeDismissPolicyTests
```
Expected: 5 tests passed.

- [ ] **Step 6: Commit**

```bash
git add iOSReader/Views/Reader/ReaderGestureHelpers.swift \
        iOSReaderTests/Views/Reader/SwipeDismissPolicyTests.swift \
git commit -m "feat(reader): add SwipeDismissPolicy helper"
```

---

## Task 4: `ReaderRoute` + `AppEnvironment` extensions

**Files:**
- Create: `iOSReader/Views/Reader/ReaderRoute.swift`
- Modify: `iOSReader/App/AppEnvironment.swift`

`fullScreenCover(item:)` requires `Identifiable`; `UUID` doesn't conform. A tiny wrapper plus the env API replaces the current `NavigationLink`/`OpenReaderRoute` pattern.

- [ ] **Step 1: Create `ReaderRoute.swift`**

Create `iOSReader/Views/Reader/ReaderRoute.swift`:

```swift
import Foundation

/// Identifiable wrapper so `fullScreenCover(item:)` can key off the active book.
/// `UUID` is `Hashable` but not `Identifiable`; this struct fills that gap.
struct ReaderRoute: Identifiable, Hashable {
    let id: UUID
}
```

- [ ] **Step 2: Add `ReaderRoute.swift` to the Xcode app target**

Xcode → right-click `iOSReader/Views/Reader/` group → **Add Files…**, target = **iOSReader** only.

- [ ] **Step 3: Modify `AppEnvironment.swift`**

In `iOSReader/App/AppEnvironment.swift`, after the `opds` property (around line 22), add a new line:

```swift
    private(set) var opds: OPDSClient?

    /// Set when a reader is open. Drives the app-wide `.fullScreenCover` in
    /// `RootView`. Hoisted above `TabView` so both Home and Browse can present
    /// without double-stacking modals.
    var activeReader: ReaderRoute?
```

Then, just before the closing brace of the class (after `static func performSignOut(...)`), add:

```swift

    /// Opens the reader for `bookID`. No-op when a reader is already open.
    func openReader(_ bookID: UUID) {
        guard activeReader == nil else { return }
        activeReader = ReaderRoute(id: bookID)
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`. (`activeReader` is unused but declared — fine.)

- [ ] **Step 5: Commit**

```bash
git add iOSReader/Views/Reader/ReaderRoute.swift \
        iOSReader/App/AppEnvironment.swift \
git commit -m "feat(reader): add ReaderRoute + openReader env API"
```

---

## Task 5: Wire `fullScreenCover` in `RootView`

**Files:**
- Modify: `iOSReader/Views/RootView.swift`

- [ ] **Step 1: Modify `RootView.swift`**

Replace the entire `body` property in `iOSReader/Views/RootView.swift` with:

```swift
    var body: some View {
        @Bindable var env = env

        Group {
            // First-run gate: if there is no OPDSClient (no credentials), force Settings.
            if env.opds == nil {
                NavigationStack { SettingsView() }
            } else {
                TabView(selection: $selectedTab) {
                    HomeRootView()
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(0)
                    BrowseRootView()
                        .tabItem { Label("Browse", systemImage: "books.vertical") }
                        .tag(1)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(2)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await env.sync?.flushAllPending() }
                    }
                }
            }
        }
        .fullScreenCover(item: $env.activeReader) { route in
            ReaderView(bookID: route.id)
        }
    }
```

The `@Bindable` projection is required because `AppEnvironment` is `@Observable` and we need a `Binding<ReaderRoute?>` for `fullScreenCover(item:)`.

- [ ] **Step 2: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`. The cover will not appear yet — nothing sets `activeReader`.

- [ ] **Step 3: Commit**

```bash
git add iOSReader/Views/RootView.swift
git commit -m "feat(reader): attach fullScreenCover to RootView"
```

---

## Task 6: Open reader from `HomeRootView`

**Files:**
- Modify: `iOSReader/Views/HomeRootView.swift`

- [ ] **Step 1: Modify the `ForEach` block**

In `iOSReader/Views/HomeRootView.swift`, replace the `ForEach(books) { book in ... }` block (currently using `NavigationLink`) with:

```swift
                        ForEach(books) { book in
                            Button {
                                env.openReader(book.id)
                            } label: {
                                HomeBookRow(book: book,
                                            progress: progressByBookID[book.id] ?? 0)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(.init(top: 0, leading: 0,
                                                 bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(book)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
```

Then add the env binding at the top of the struct (after the `@Environment(\.modelContext)` line):

```swift
    @Environment(AppEnvironment.self) private var env
```

(`HomeBookRow` already has it, but `HomeRootView` itself does not.)

- [ ] **Step 2: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add iOSReader/Views/HomeRootView.swift
git commit -m "feat(reader): Home opens reader via env.openReader"
```

---

## Task 7: Open reader from `FeedView` + retire `OpenReaderRoute`

**Files:**
- Modify: `iOSReader/Views/FeedView.swift`
- Modify: `iOSReader/Views/BrowseRootView.swift`

- [ ] **Step 1: Modify `FeedView.act(...)`**

In `iOSReader/Views/FeedView.swift`, replace the body of `act(entry:format:)` (currently lines 114-130) with:

```swift
    private func act(entry: AcquisitionEntry, format: BookFormat) {
        if let existing = BookActions.findBook(serverID: entry.serverID,
                                               format: format, context: modelContext),
           existing.filename != nil {
            env.openReader(existing.id)
            return
        }
        guard let chosen = entry.acquisitions.first(where: { $0.format == format })
        else { return }
        let book = BookActions.upsertBook(entry: entry, chosen: chosen,
                                          context: modelContext)
        // Kick off the download in the background and open the reader
        // immediately. ReaderView shows a downloading-state UI until the
        // file lands, then transitions to the actual EPUB navigator.
        Task { _ = try? await env.downloads?.download(book: book) }
        env.openReader(book.id)
    }
```

- [ ] **Step 2: Modify `BrowseRootView.swift`**

In `iOSReader/Views/BrowseRootView.swift`, remove the `navigationDestination(for: OpenReaderRoute.self)` block (lines 25-27 in the original) and the `OpenReaderRoute` struct itself (lines 72-74). The resulting `NavigationStack` block:

```swift
        NavigationStack(path: $path) {
            Group {
                if let loader = rootLoader {
                    FeedView(feedURL: loader.initialURL, path: $path)
                        .navigationTitle("Browse")
                } else {
                    ProgressView().task { setup() }
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                FeedView(feedURL: route.url, path: $path)
                    .navigationTitle("Results: \(route.query)")
            }
        }
```

And delete the entire struct declaration:

```swift
struct OpenReaderRoute: Hashable {
    let bookID: UUID
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add iOSReader/Views/FeedView.swift \
        iOSReader/Views/BrowseRootView.swift
git commit -m "feat(reader): Browse opens reader via env.openReader; drop OpenReaderRoute"
```

---

## Task 8: Open reader from `BookDetailView`

**Files:**
- Modify: `iOSReader/Views/BookDetailView.swift`

- [ ] **Step 1: Replace the `NavigationLink`**

In `iOSReader/Views/BookDetailView.swift`, replace the `NavigationLink("Open") { ReaderView(bookID: book.id) }` line (line 40) with:

```swift
                Button("Open") { env.openReader(book.id) }
```

If `env` is not already in the view, add `@Environment(AppEnvironment.self) private var env` near the top of the struct's properties.

- [ ] **Step 2: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add iOSReader/Views/BookDetailView.swift
git commit -m "feat(reader): BookDetailView opens reader via env.openReader"
```

---

## Task 9: Move `ReaderView`/`ReaderHost` into `Reader/` subfolder

**Files:**
- Move: `iOSReader/Views/ReaderView.swift` → `iOSReader/Views/Reader/ReaderView.swift`
- Create: `iOSReader/Views/Reader/ReaderHost.swift` (extracted)

This task is structural — no behaviour changes yet. It separates the SwiftUI shell from the UIViewController representable so subsequent tasks can edit them independently.

- [ ] **Step 1: Move `ReaderView.swift`**

```bash
git mv iOSReader/Views/ReaderView.swift iOSReader/Views/Reader/ReaderView.swift
```

- [ ] **Step 2: Extract `ReaderHost` and `DownloadingView` into separate files**

Open `iOSReader/Views/Reader/ReaderView.swift`. Cut everything from `// MARK: - DownloadingView` to the end of `private struct DownloadingView` and save into a new file `iOSReader/Views/Reader/DownloadingView.swift`. Cut everything from `// MARK: - ReaderHost` to the end of file (the `ReaderHost` struct) and save into `iOSReader/Views/Reader/ReaderHost.swift`.

`iOSReader/Views/Reader/DownloadingView.swift` should be:

```swift
import SwiftUI
import SwiftData

struct DownloadingView: View {
    let book: Book
    let download: Download?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            if let download, download.state == .failed {
                VStack(spacing: 12) {
                    Text(download.error ?? "Download failed")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button("Retry") {
                        Task { _ = try? await env.downloads?.download(book: book) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 8) {
                    if let download, download.totalBytes > 0 {
                        ProgressView(value: Double(download.bytesReceived),
                                     total: Double(download.totalBytes))
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 32)

                        Text(progressLabel(download))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    private func progressLabel(_ download: Download) -> String {
        let received = ByteCountFormatter.string(fromByteCount: download.bytesReceived,
                                                  countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytes,
                                               countStyle: .file)
        return "\(received) of \(total)"
    }
}
```

Note: the diagnostic strip from the original is dropped — it was tagged "temporary while we debug the 'stuck on Preparing' path" in the source. The download flow has since stabilised; drop it as part of this move.

`iOSReader/Views/Reader/ReaderHost.swift` (initial extraction — Task 12 will rewrite this):

```swift
import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Wraps a Readium navigator in a UIViewControllerRepresentable.
/// Supports EPUB only in v1 (PDF/CBZ require an HTTPServer adapter not included
/// in the current dependency set).
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    var onLocatorChange: @Sendable (Locator) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onLocatorChange)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            do {
                let nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initialLocator
                )
                nav.delegate = context.coordinator
                return nav
            } catch {
                return errorController("Failed to open EPUB: \(error.localizedDescription)")
            }
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, EPUBNavigatorDelegate, @unchecked Sendable {
        let onChange: @Sendable (Locator) -> Void

        init(onChange: @escaping @Sendable (Locator) -> Void) {
            self.onChange = onChange
        }

        nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onChange(locator)
        }

        nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    }

    private func errorController(_ message: String) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -24),
        ])
        return vc
    }
}
```

`iOSReader/Views/Reader/ReaderView.swift` should now contain only the `ReaderView` struct (and its `PromptInfo` + `OpenError` nested types).

- [ ] **Step 3: Update Xcode project**

In Xcode → drag the existing `ReaderView.swift` reference to the new `Reader/` group (Xcode tracks the move). Add the two new files (`DownloadingView.swift`, `ReaderHost.swift`) via **Add Files…** with target = **iOSReader**.

- [ ] **Step 4: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add iOSReader/Views/Reader/ iOSReader/Views/ReaderView.swift \
git commit -m "refactor(reader): move ReaderView and split out ReaderHost / DownloadingView"
```

---

## Task 10: `ReaderInputHandlers` (UIKit recognizers)

**Files:**
- Create: `iOSReader/Views/Reader/ReaderInputHandlers.swift`

Owns the tap and pinch recognizers. Attaches them to a host view (the container VC's view). Exposes callbacks. Uses `TapZoneClassifier` to dispatch.

- [ ] **Step 1: Create the file**

Create `iOSReader/Views/Reader/ReaderInputHandlers.swift`:

```swift
import UIKit

/// Owns the tap + pinch recognizers attached to a host view (the reader
/// container's view). Calls back to the container with classified events.
///
/// Recognizers attach to the *container's* view, not a transparent overlay
/// subview, because Readium's WebView is a descendant of the container's
/// view — a recognizer on the parent sees touches from all descendants
/// without needing a subview that would interfere with hit-testing.
///
/// The tap recognizer has `cancelsTouchesInView = true` so Readium's
/// built-in tap-to-turn behaviour is suppressed; otherwise both would fire.
/// Long-press (text selection) is a separate recognizer in Readium's
/// WebViews and is unaffected.
@MainActor
final class ReaderInputHandlers: NSObject {
    /// Called for taps in the left 25 %.
    var onLeftTap: (() -> Void)?
    /// Called for taps in the center 50 %.
    var onCenterTap: (() -> Void)?
    /// Called for taps in the right 25 %.
    var onRightTap: (() -> Void)?
    /// Pinch began or changed — payload is the target percent for the HUD
    /// (or `nil` to dismiss the HUD when the gesture cancelled).
    var onPinchUpdate: ((Int?) -> Void)?
    /// Pinch ended successfully — payload is the percent to commit.
    var onPinchCommit: ((Int) -> Void)?

    /// The font-size percent that was in effect when the pinch began.
    /// Captured at `.began` so subsequent `.changed` events scale from
    /// the same anchor even as we update the HUD.
    private var pinchStartPct: Int = 100

    /// Closure that returns the currently-committed percent. Kept as a
    /// closure (not a value) so it always reflects the latest `@AppStorage`
    /// without us having to re-set a property on every change.
    private let currentFontSizePct: () -> Int

    init(currentFontSizePct: @escaping () -> Int) {
        self.currentFontSizePct = currentFontSizePct
        super.init()
    }

    func attach(to view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        // Absorbs the touch so Readium's WebView never sees it as a tap —
        // suppresses Readium's built-in tap-to-turn-page behaviour.
        tap.cancelsTouchesInView = true
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard let host = gr.view else { return }
        let x = gr.location(in: host).x
        switch TapZoneClassifier.classify(x: x, width: host.bounds.width) {
        case .left:   onLeftTap?()
        case .center: onCenterTap?()
        case .right:  onRightTap?()
        }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            pinchStartPct = currentFontSizePct()
            onPinchUpdate?(pinchStartPct)
        case .changed:
            let target = FontSizeStep.clamp(startPct: pinchStartPct, scale: gr.scale)
            onPinchUpdate?(target)
        case .ended:
            let target = FontSizeStep.clamp(startPct: pinchStartPct, scale: gr.scale)
            onPinchCommit?(target)
        case .cancelled, .failed:
            onPinchUpdate?(nil)
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Add to Xcode app target**

Xcode → **Add Files…** under `iOSReader/Views/Reader/`, target = **iOSReader** only.

- [ ] **Step 3: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED` (class is defined but unused — fine for now).

- [ ] **Step 4: Commit**

```bash
git add iOSReader/Views/Reader/ReaderInputHandlers.swift \
git commit -m "feat(reader): add ReaderInputHandlers for tap + pinch recognizers"
```

---

## Task 11: `ReaderContainerVC` (UIKit container)

**Files:**
- Create: `iOSReader/Views/Reader/ReaderContainerVC.swift`

UIKit container that hosts the Readium navigator as a child VC. Owns:
- `ReaderInputHandlers` attached to its view
- `UIKeyCommand`s for `←` / `→` / `ESC`
- Status-bar visibility (`prefersStatusBarHidden`)
- Font-size application via `submitPreferences`

- [ ] **Step 1: Create the file**

Create `iOSReader/Views/Reader/ReaderContainerVC.swift`:

```swift
import UIKit
import ReadiumShared
import ReadiumNavigator

/// UIKit container that hosts `EPUBNavigatorViewController` as a child VC
/// and owns the input layer (taps, pinch, hardware keys, status-bar control).
@MainActor
final class ReaderContainerVC: UIViewController {

    // MARK: - Callbacks

    var onLocatorChange: ((Locator) -> Void)?
    var onCenterTap: (() -> Void)?
    var onPinchUpdate: ((Int?) -> Void)?
    var onDismissRequested: (() -> Void)?

    // MARK: - Inputs (set via update())

    private(set) var fontSizePct: Int = 100
    private(set) var statusBarHidden: Bool = true

    // MARK: - Internals

    private let publication: Publication
    private let initialLocator: Locator?
    private var navigator: EPUBNavigatorViewController?
    private var inputHandlers: ReaderInputHandlers?

    init(publication: Publication, initialLocator: Locator?) {
        self.publication = publication
        self.initialLocator = initialLocator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installNavigator()
        installInputHandlers()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First-responder is required for `UIKeyCommand`s to fire.
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { statusBarHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    // MARK: - Updates from SwiftUI

    /// Called from `ReaderHost.updateUIViewController` whenever SwiftUI re-renders.
    func update(fontSizePct: Int, statusBarHidden: Bool) {
        if self.fontSizePct != fontSizePct {
            self.fontSizePct = fontSizePct
            applyFontSize()
        }
        if self.statusBarHidden != statusBarHidden {
            self.statusBarHidden = statusBarHidden
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: - Navigator setup

    private func installNavigator() {
        let prefs = EPUBPreferences(fontSize: Double(fontSizePct) / 100.0)
        let config = EPUBNavigatorViewController.Configuration(preferences: prefs)
        do {
            let nav = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocator,
                config: config
            )
            nav.delegate = self
            addChild(nav)
            nav.view.frame = view.bounds
            nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(nav.view)
            nav.didMove(toParent: self)
            self.navigator = nav
        } catch {
            installErrorLabel("Failed to open EPUB: \(error.localizedDescription)")
        }
    }

    private func installErrorLabel(_ message: String) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    // MARK: - Input handlers

    private func installInputHandlers() {
        let handlers = ReaderInputHandlers(currentFontSizePct: { [weak self] in
            self?.fontSizePct ?? 100
        })
        handlers.onLeftTap = { [weak self] in self?.turnBackward() }
        handlers.onRightTap = { [weak self] in self?.turnForward() }
        handlers.onCenterTap = { [weak self] in self?.onCenterTap?() }
        handlers.onPinchUpdate = { [weak self] pct in self?.onPinchUpdate?(pct) }
        handlers.onPinchCommit = { [weak self] pct in
            // The container is the only place that owns the navigator handle.
            // Apply the preferences here; SwiftUI also writes @AppStorage,
            // which round-trips back via `update(fontSizePct:)` — that path
            // is a no-op because `fontSizePct` will already equal `pct`.
            self?.fontSizePct = pct
            self?.applyFontSize()
            self?.onPinchUpdate?(nil)  // dismiss HUD
            self?.onPinchCommitToSwiftUI?(pct)
        }
        handlers.attach(to: view)
        self.inputHandlers = handlers
    }

    /// Bridges pinch commit out to SwiftUI so it can persist via @AppStorage.
    var onPinchCommitToSwiftUI: ((Int) -> Void)?

    // MARK: - Page turns

    private func turnForward() {
        guard let nav = navigator else { return }
        Task { _ = await nav.goForward(options: NavigatorGoOptions(animated: false)) }
    }

    private func turnBackward() {
        guard let nav = navigator else { return }
        Task { _ = await nav.goBackward(options: NavigatorGoOptions(animated: false)) }
    }

    // MARK: - Font size

    private func applyFontSize() {
        guard let nav = navigator else { return }
        let prefs = EPUBPreferences(fontSize: Double(fontSizePct) / 100.0)
        nav.submitPreferences(prefs)
    }

    // MARK: - Hardware keys

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                title: "Next Page",
                action: #selector(keyForward),
                input: UIKeyCommand.inputRightArrow,
                discoverabilityTitle: "Next Page"
            ),
            UIKeyCommand(
                title: "Previous Page",
                action: #selector(keyBackward),
                input: UIKeyCommand.inputLeftArrow,
                discoverabilityTitle: "Previous Page"
            ),
            UIKeyCommand(
                title: "Close",
                action: #selector(keyDismiss),
                input: UIKeyCommand.inputEscape,
                discoverabilityTitle: "Close Reader"
            ),
        ]
    }

    @objc private func keyForward() { turnForward() }
    @objc private func keyBackward() { turnBackward() }
    @objc private func keyDismiss() { onDismissRequested?() }
}

// MARK: - EPUBNavigatorDelegate

extension ReaderContainerVC: EPUBNavigatorDelegate {
    nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        Task { @MainActor [weak self] in
            self?.onLocatorChange?(locator)
        }
    }

    nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
}
```

- [ ] **Step 2: Add to Xcode app target**

Xcode → **Add Files…**, target = **iOSReader** only.

- [ ] **Step 3: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`. (Container exists but isn't referenced; Task 12 wires it in.)

- [ ] **Step 4: Commit**

```bash
git add iOSReader/Views/Reader/ReaderContainerVC.swift \
git commit -m "feat(reader): add ReaderContainerVC with input, keys, font-size handling"
```

---

## Task 12: Refactor `ReaderHost` to wrap `ReaderContainerVC`

**Files:**
- Modify: `iOSReader/Views/Reader/ReaderHost.swift`

- [ ] **Step 1: Replace `ReaderHost.swift` contents**

Replace `iOSReader/Views/Reader/ReaderHost.swift` with:

```swift
import SwiftUI
import UIKit
import ReadiumShared
import ReadiumNavigator

/// Wraps `ReaderContainerVC` for SwiftUI. The host carries inputs (font size,
/// status-bar visibility) and outputs (locator changes, taps, pinch, dismiss).
/// EPUB only in v1; non-EPUB publications surface an error label.
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    let fontSizePct: Int
    let statusBarHidden: Bool
    var onLocatorChange: @Sendable (Locator) -> Void
    var onCenterTap: () -> Void
    var onPinchUpdate: (Int?) -> Void
    var onPinchCommit: (Int) -> Void
    var onDismissRequested: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            let vc = ReaderContainerVC(publication: publication, initialLocator: initialLocator)
            vc.update(fontSizePct: fontSizePct, statusBarHidden: statusBarHidden)
            vc.onLocatorChange = { locator in onLocatorChange(locator) }
            vc.onCenterTap = onCenterTap
            vc.onPinchUpdate = onPinchUpdate
            vc.onPinchCommitToSwiftUI = onPinchCommit
            vc.onDismissRequested = onDismissRequested
            return vc
        } else {
            return errorController(
                "Only EPUB is supported in this version.\nPDF and CBZ require an HTTP server adapter."
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let container = uiViewController as? ReaderContainerVC else { return }
        container.update(fontSizePct: fontSizePct, statusBarHidden: statusBarHidden)
        // Re-bind callbacks each update — SwiftUI may have re-created closures.
        container.onLocatorChange = { locator in onLocatorChange(locator) }
        container.onCenterTap = onCenterTap
        container.onPinchUpdate = onPinchUpdate
        container.onPinchCommitToSwiftUI = onPinchCommit
        container.onDismissRequested = onDismissRequested
    }

    private func errorController(_ message: String) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: vc.view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: vc.view.trailingAnchor, constant: -24),
        ])
        return vc
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: build will **fail** — `ReaderView` still constructs `ReaderHost` with the old signature. That's fine; Task 14 fixes it. Skip the build step.

- [ ] **Step 3: Commit**

```bash
git add iOSReader/Views/Reader/ReaderHost.swift
git commit -m "refactor(reader): rewire ReaderHost to wrap ReaderContainerVC"
```

(Note: the build is intentionally broken between Tasks 12 and 14; both are small enough to keep open. Do not let Task 12 sit on a feature branch overnight without Task 14.)

---

## Task 13: `ReaderChrome` SwiftUI views

**Files:**
- Create: `iOSReader/Views/Reader/ReaderChrome.swift`

- [ ] **Step 1: Create the file**

Create `iOSReader/Views/Reader/ReaderChrome.swift`:

```swift
import SwiftUI
import ReadiumShared

/// Top bar shown when chrome is visible. Close button on the left,
/// truncated title in the middle, nothing on the right.
struct ReaderTopBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Right-side spacer keeps the title visually centered against the
            // close button's 44pt hit target.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.regularMaterial)
        // Absorb taps anywhere in the bar so they don't reach the page
        // beneath (otherwise a tap on empty title area would turn the page).
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Bottom strip with progress bar and `34% • Chapter 4` label.
struct ReaderBottomProgressBar: View {
    let locator: Locator?

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                Text("•")
                    .font(.caption)
                Text(chapterLabel)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        // Absorb taps so the page beneath doesn't see them.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var progress: Double {
        locator?.locations.totalProgression ?? 0
    }

    private var chapterLabel: String {
        // `Locator.title` is the chapter heading where Readium can resolve it.
        if let title = locator?.title, !title.isEmpty {
            return title
        }
        return "Chapter ?"
    }
}

/// Centered HUD shown during a pinch. "120%" inside a rounded background.
struct ReaderFontHUD: View {
    let pct: Int

    var body: some View {
        Text("\(pct)%")
            .font(.title2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Font size \(pct) percent")
    }
}
```

- [ ] **Step 2: Add to Xcode app target**

Xcode → **Add Files…**, target = **iOSReader** only.

- [ ] **Step 3: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: still broken (Task 12's mismatch) — skip.

- [ ] **Step 4: Commit**

```bash
git add iOSReader/Views/Reader/ReaderChrome.swift \
git commit -m "feat(reader): add ReaderChrome views (top bar, bottom strip, font HUD)"
```

---

## Task 14: Refactor `ReaderView` shell + chrome composition

**Files:**
- Modify: `iOSReader/Views/Reader/ReaderView.swift`

Final wiring: `@AppStorage`, `@State` for transient UI, `ZStack` with `ReaderHost` plus conditional chrome, swipe-down `DragGesture`, `.dismiss` from the environment.

- [ ] **Step 1: Replace `ReaderView.swift`**

Replace the contents of `iOSReader/Views/Reader/ReaderView.swift` with:

```swift
import SwiftUI
import SwiftData
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator
import Core

/// Immersive reader. Presented as a `fullScreenCover` from `RootView`.
struct ReaderView: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @Query private var books: [Book]
    @Query private var downloads: [Download]

    @AppStorage("reader.fontSizePct") private var fontSizePct: Int = 100

    @State private var publication: Publication?
    @State private var initialLocator: Locator?
    @State private var loadError: String?
    @State private var pendingPrompt: PromptInfo?

    @State private var uiVisible: Bool = false
    @State private var fontHUD: Int? = nil
    @State private var currentLocator: Locator?

    init(bookID: UUID) {
        self.bookID = bookID
        let id = bookID
        _books = Query(filter: #Predicate<Book> { $0.id == id })
        _downloads = Query(filter: #Predicate<Download> { $0.bookID == id })
    }

    private var book: Book? { books.first }
    private var download: Download? { downloads.first }

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: ProgressDownload
    }

    var body: some View {
        ZStack {
            content
            chromeOverlay
            hudOverlay
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .simultaneousGesture(swipeDownDismissGesture())
        .task(id: book?.fileURL) { await loadPublicationIfReady() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await flush() }
            }
        }
        .onDisappear {
            Task { await flush() }
            // Clear the env binding so the modal can be reopened on the same book.
            env.activeReader = nil
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if let book {
            if book.fileURL != nil, let publication {
                let id = book.id
                ReaderHost(
                    publication: publication,
                    initialLocator: initialLocator,
                    fontSizePct: fontSizePct,
                    statusBarHidden: !uiVisible,
                    onLocatorChange: { @Sendable locator in
                        Task { @MainActor in
                            currentLocator = locator
                            await pushLocator(bookID: id, locator: locator)
                        }
                    },
                    onCenterTap: { withAnimation(.easeOut(duration: 0.2)) { uiVisible.toggle() } },
                    onPinchUpdate: { pct in
                        // Spec: fade-in 0.15s, fade-out 0.3s.
                        let duration = (pct == nil) ? 0.3 : 0.15
                        withAnimation(.easeOut(duration: duration)) { fontHUD = pct }
                    },
                    onPinchCommit: { pct in
                        fontSizePct = pct
                        // HUD already cleared by container's onPinchUpdate(nil); animate fade-out.
                    },
                    onDismissRequested: { dismiss() }
                )
                .task { await onOpen(book: book) }
                .alert(item: $pendingPrompt) { info in
                    Alert(
                        title: Text("Continue from another device?"),
                        message: Text(
                            "\(Int(info.server.percentage * 100))% on '\(info.server.device)'"
                        ),
                        primaryButton: .default(Text("Continue")) {
                            // v1: silently accept; next locator change reconciles with the server.
                        },
                        secondaryButton: .cancel(Text("Stay here"))
                    )
                }
            } else if book.fileURL == nil {
                DownloadingView(book: book, download: download)
            } else if let loadError {
                Text(loadError).foregroundStyle(.orange).padding()
            } else {
                ProgressView("Opening…").tint(.white)
            }
        } else {
            Text("Book not found").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        if uiVisible {
            VStack(spacing: 0) {
                ReaderTopBar(title: book?.title ?? "", onClose: { dismiss() })
                Spacer()
                ReaderBottomProgressBar(locator: currentLocator)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var hudOverlay: some View {
        if let pct = fontHUD {
            ReaderFontHUD(pct: pct)
                .transition(.opacity)
        }
    }

    // MARK: - Swipe-down dismiss

    private func swipeDownDismissGesture() -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let translation = CGSize(width: value.translation.width,
                                         height: value.translation.height)
                let velocity = CGSize(width: value.predictedEndTranslation.width - value.translation.width,
                                      height: value.predictedEndTranslation.height - value.translation.height)
                if SwipeDismissPolicy.shouldDismiss(translation: translation, velocity: velocity) {
                    dismiss()
                }
            }
    }

    // MARK: - Publication loading (unchanged from prior file)

    private func loadPublicationIfReady() async {
        guard let book, let fileURL = book.fileURL else { return }
        let id = bookID
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            initialLocator = try? Locator(jsonString: progress.locatorJSON)
        }
        do {
            publication = try await openPublication(at: fileURL)
        } catch {
            let diagnostics = fileDiagnostics(at: fileURL)
            loadError = "Failed to open:\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n\(diagnostics)"
        }
    }

    private func fileDiagnostics(at url: URL) -> String {
        var lines: [String] = []
        lines.append("URL: \(url.absoluteString)")
        lines.append("Scheme: \(url.scheme ?? "<none>")")
        lines.append("Path: \(url.path)")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        lines.append("Exists: \(exists)")
        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                lines.append("Size: \(size) bytes")
            }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let head = handle.readData(ofLength: 4)
                lines.append("Head: \(head.map { String(format: "%02x", $0) }.joined())")
            } else {
                lines.append("Head: <unreadable>")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw OpenError.invalidFileURL(url)
        }

        let asset = try await assetRetriever.retrieve(url: fileURL)
            .mapError { OpenError.asset($0) }
            .get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        return try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { OpenError.publication($0) }
            .get()
    }

    private enum OpenError: LocalizedError {
        case invalidFileURL(URL)
        case asset(AssetRetrieveURLError)
        case publication(PublicationOpenError)

        var errorDescription: String? {
            switch self {
            case .invalidFileURL(let url):
                return "Readium rejected the file URL: \(url.absoluteString)"
            case .asset(let inner):
                return "Asset retrieval failed: \(Self.describe(inner))"
            case .publication(let inner):
                return "Publication open failed: \(inner.localizedDescription)"
            }
        }

        private static func describe(_ error: AssetRetrieveURLError) -> String {
            switch error {
            case .schemeNotSupported(let scheme):
                return "scheme '\(scheme.rawValue)' not supported"
            case .formatNotSupported:
                return "format not recognized (sniffer found no specifications — wrong extension / corrupted file / missing file)"
            case .reading(let inner):
                return "read error: \(inner.localizedDescription)"
            }
        }
    }

    private func onOpen(book: Book) async {
        guard let sync = env.sync else { return }
        do {
            switch try await sync.onOpen(book: book) {
            case .useLocal: break
            case .applyServer: break
            case .promptUser(let local, let server):
                pendingPrompt = PromptInfo(local: local, server: server)
            }
        } catch {
            // Best-effort onOpen; ignore failures.
        }
    }

    private func currentBook() -> Book? {
        let id = bookID
        return try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func flush() async {
        guard let sync = env.sync, let book = currentBook() else { return }
        await sync.flushPendingProgress(for: book)
    }

    private func pushLocator(bookID: UUID, locator: Locator) async {
        guard let book = currentBook() else { return }
        let intra = locator.locations.progression ?? 0
        let total = locator.locations.totalProgression ?? 0
        guard let json = locator.jsonString else { return }
        env.sync?.bufferLocator(
            book: book, locatorJSON: json,
            chapter: 0, intraProgression: intra, percentage: total
        )
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run all tests**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: all tests pass (helper tests added in Tasks 1–3 plus existing suites).

- [ ] **Step 4: Commit**

```bash
git add iOSReader/Views/Reader/ReaderView.swift
git commit -m "feat(reader): immersive ReaderView with chrome, font HUD, swipe dismiss"
```

---

## Task 15: Manual smoke test on simulator + iPad

Tasks 1–14 cover the unit-testable surface. The interactions themselves can only be verified on a device / simulator.

- [ ] **Step 1: iPhone simulator (touch only)**

Launch the app on `iPhone 16`:

```bash
xcodebuild build -project iOSReader.xcodeproj -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
open -a Simulator
xcrun simctl boot "iPhone 16" 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/iOSReader-*/Build/Products/Debug-iphonesimulator/iOSReader.app
xcrun simctl launch booted me.iosreader.iOSReader
```

Smoke-test checklist (mark each pass/fail in a follow-up comment if any fails):

- Open a downloaded book from Home — modal slides up, no nav bar.
- Tap left 25 % of the page — page turns back (no animation).
- Tap right 25 % — page turns forward (no animation).
- Tap center — top bar + bottom strip fade in; status bar appears.
- Tap center again — chrome fades out; status bar hides.
- With chrome visible: tap the `X` button → modal dismisses.
- Pinch out — HUD shows percent rising in 10-step jumps; release → reflow lands at HUD's last shown value.
- Pinch in — symmetric.
- Re-open the same book — font size persists.
- Swipe down from anywhere on the page body — modal dismisses.
- Swipe sideways — no dismissal; page turn does not fire (we don't bind taps to drag end).

- [ ] **Step 2: iPad simulator (keyboard)**

```bash
xcodebuild build -project iOSReader.xcodeproj -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPad Pro (12.9-inch) (6th generation)'
```

Boot the iPad simulator, enable **I/O → Keyboard → Connect Hardware Keyboard**, then:

- Open a book. Press `→` → page advances. Press `←` → page retreats.
- Press `⌘` (hold) — the discoverability sheet shows "Next Page / Previous Page / Close Reader".
- Press `ESC` → modal dismisses.
- Re-open a book, toggle chrome on, press `→` → page advances and chrome stays visible.

- [ ] **Step 3: Regression checks**

- Switch tabs while reader is closed — tab selection works (the pinned `selectedTab` behavior is preserved).
- Open from Browse → download path: modal appears showing `DownloadingView`, transitions to the EPUB once download lands.
- Open from Browse → already-downloaded path: modal appears with the EPUB directly.
- Backgrounding the app while reading flushes the locator (no behavior change vs. before).

- [ ] **Step 4: Commit the test pass log (optional)**

If you keep a manual-test log file in the repo, append the date and results. Otherwise, no commit.

---

## Task 16: Final cleanup

- [ ] **Step 1: Check for leftover diagnostics or comments**

```bash
git diff main..HEAD -- iOSReader/Views/Reader/ | grep -i "TODO\|FIXME\|temporary\|debug" || true
```
Expected: no matches (the diagnostic strip in `DownloadingView` was dropped in Task 9; `ReaderView.swift`'s removed strip is also gone).

- [ ] **Step 2: Run full test suite once more**

```bash
xcodebuild test \
  -project iOSReader.xcodeproj \
  -scheme iOSReader \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: green.

- [ ] **Step 3: Final commit if anything changed**

```bash
git status
# If clean: done.
# If anything was missed:
git add -p
git commit -m "chore(reader): cleanup pass"
```

---

## Done criteria

- All checkbox items in Tasks 1–16 are checked.
- All unit tests pass.
- The smoke-test checklist in Task 15 is green on iPhone + iPad simulators.
- `git log feat/v1..HEAD` shows the commits in order; no `--no-verify`, no `--amend`, no destructive history rewrites.
