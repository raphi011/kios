# Reader View Improvements — Design

**Date:** 2026-05-11
**Status:** Draft (awaiting user review)
**Scope:** Replace the current pushed `ReaderView` with an immersive modal
reader that supports edge-tap page turns, pinch-to-resize font, hardware
keys, swipe-down dismiss, and a tap-to-reveal chrome.

## Goals

- Reader is an immersive **mode**, not a navigation destination.
- Touch interactions: tap-edges to turn pages, pinch to resize font, tap-center to reveal/hide chrome, swipe-down to close.
- Hardware keys (iPad / Mac Catalyst): `←` / `→` to turn pages, `ESC` to close.
- Chrome is hidden by default. When visible, it shows a top bar (close + title) and a bottom strip (`34% • Chapter 4`).
- Font size persists globally across the app.

## Non-goals (v1)

- Drag-to-scrub the bottom progress bar.
- Theme picker, brightness, line spacing, font family.
- Per-book font size.
- Animated rubber-band translation during swipe-down (hard threshold only).
- Configurable tap-zone widths.
- `⋯` settings menu in the top bar.

Each of these has a natural extension point in the design and can be added later without redesign.

## Architecture

Hybrid UIKit-for-input / SwiftUI-for-chrome layering. The input layer lives where Readium already lives (UIKit); the chrome layer lives where SwiftUI is strongest (declarative conditional rendering). A single `@State` flag bridges them.

```
RootView
 ├─ HomeRootView ──── row tap ────┐
 ├─ BrowseRootView ── open ───────┼─► env.openReader(bookID)
                                   │
AppEnvironment                     ▼
 └─ @Observable activeReader: ReaderRoute?     // ReaderRoute: Identifiable wrapper around UUID

RootView.fullScreenCover(item: $env.activeReader) { route in
    ReaderView(bookID: route.id)
}

ReaderView (SwiftUI)
 ├─ @State uiVisible: Bool = false
 ├─ @State fontHUD: Int? = nil          // during pinch
 ├─ @AppStorage("reader.fontSizePct") fontSizePct: Int = 100
 ├─ @State currentLocator: Locator?
 │
 └─ ZStack {
      ReaderHost(
        publication, initialLocator, fontSizePct,
        onLocatorChange,
        onCenterTap, onPinchUpdate, onPinchCommit,
        onDismissRequested
      )
      if uiVisible { TopBar(); BottomProgressBar(locator: currentLocator) }
      if let pct = fontHUD { FontSizeHUD(pct) }
    }
    .gesture(DragGesture …)            // swipe-down dismiss

ReaderHost : UIViewControllerRepresentable
 └─ wraps ReaderContainerVC; passes fontSizePct into updateUIViewController

ReaderContainerVC : UIViewController
 ├─ child: EPUBNavigatorViewController       (existing dependency)
 ├─ overlay: ReaderInputView                 (transparent)
 ├─ UIKeyCommands: ←, →, ESC
 ├─ applies EPUBPreferences on fontSizePct change
 └─ canBecomeFirstResponder = true; becomeFirstResponder in viewDidAppear

ReaderInputView : UIView
 ├─ UITapGestureRecognizer (single tap, classified by x)
 ├─ UIPinchGestureRecognizer
 └─ hitTest passes long-press/drag through to underlying WebView
```

### New / changed files

- `Views/Reader/ReaderView.swift` — refactored shell + chrome state (existing file, moved into `Reader/` subfolder for cohesion).
- `Views/Reader/ReaderHost.swift` — slimmer `UIViewControllerRepresentable`.
- `Views/Reader/ReaderContainerVC.swift` — **new**, UIKit container hosting the navigator + input overlay + key commands.
- `Views/Reader/ReaderInputView.swift` — **new**, transparent UIView with tap + pinch recognizers.
- `Views/Reader/ReaderChrome.swift` — **new**, SwiftUI `TopBar`, `BottomProgressBar`, `FontSizeHUD`.
- `Views/Reader/ReaderGestureHelpers.swift` — **new**, pure functions: `TapZoneClassifier`, `FontSizeStep`, `SwipeDismissPolicy`.
- `App/AppEnvironment.swift` — add `@Observable` property `activeReader: ReaderRoute?` and `openReader(_ id: UUID)` method. `ReaderRoute` is a tiny `Identifiable` wrapper (`struct ReaderRoute: Identifiable { let id: UUID }`) because `UUID` itself is not `Identifiable` — `fullScreenCover(item:)` requires `Identifiable`.
- `Views/RootView.swift` — attach `.fullScreenCover(item: $env.activeReader) { route in ReaderView(bookID: route.id) }`.
- `Views/HomeRootView.swift` — `NavigationLink { ReaderView }` → `Button { env.openReader(book.id) }`.
- `Views/BrowseRootView.swift` — remove `navigationDestination(for: OpenReaderRoute.self)` block; tap calls `env.openReader(...)`.

## Behavioral specs

### Tap zones (25 / 50 / 25)

Classification by initial touch:

| `x / width` | Action |
|---|---|
| `< 0.25` | `navigator.goBackward(animated: false)` |
| `0.25 … 0.75` | toggle `uiVisible` |
| `> 0.75` | `navigator.goForward(animated: false)` |

- Page turns: no animation (matches requirement).
- Chrome toggle: 0.2s `.easeOut` opacity fade.
- Readium's built-in tap-nav is disabled via config so taps don't double-fire.
- A tap that drifts > 10pt becomes a drag and is ignored by the tap recognizer (system default).
- When chrome is visible, taps on the bars are absorbed by the SwiftUI chrome; the input layer only sees taps on the body region.

### Hardware keys (`UIKeyCommand`)

| Key | Action |
|---|---|
| `→` (`inputRightArrow`) | `goForward(animated: false)` |
| `←` (`inputLeftArrow`) | `goBackward(animated: false)` |
| `␛` (`inputEscape`) | `onDismissRequested()` → SwiftUI `dismiss()` |

- Commands have `discoverabilityTitle` so they appear in iPad's `⌘`-key help sheet.
- `ReaderContainerVC.canBecomeFirstResponder = true`; `becomeFirstResponder()` called in `viewDidAppear`. If first-responder is lost on scene re-entry, `scenePhase == .active` triggers another `becomeFirstResponder()` call.

### Pinch to zoom

- Range: 60 % – 200 %, 10 % steps.
- Persistence: global, `@AppStorage("reader.fontSizePct")`, default 100.
- State machine:

| Phase | Behavior |
|---|---|
| `.began` | Snapshot `startPct = fontSizePct`. Post `onPinchUpdate(startPct)`. |
| `.changed` | `target = clamp(round(startPct × scale / 10) × 10, 60, 200)`. Post `onPinchUpdate(target)`. **Do not** apply to navigator yet. |
| `.ended` | Post `onPinchCommit(target)`. SwiftUI writes `@AppStorage`. `updateUIViewController` applies `EPUBPreferences(fontSize: target / 100)` to the navigator **once**. |
| `.cancelled` / `.failed` | Post `onPinchUpdate(nil)`. No commit. |

- HUD: centered rounded rect with the target %; fades in 0.15s on first update, fades out 0.3s after `.ended`.
- Rationale for commit-on-release: every preference change in Readium triggers a WebKit reflow. Committing per-frame is visibly janky.
- If a second pinch starts before reflow finishes, the new `startPct` is the **committed** value (`@AppStorage`), not any in-flight target — prevents drift.

### Swipe-down dismiss

- `DragGesture(minimumDistance: 20)` at the `ReaderView` level, `simultaneousGesture` so it doesn't steal text-selection long-presses.
- Dismiss when **all** three hold at gesture end:
  - `translation.height > 120`
  - `velocity.height > 0` (downward)
  - `abs(translation.height) > 1.5 × abs(translation.width)` (vertical-dominant)
- v1 does **not** track-and-translate the view during the drag (no rubber-band). Hard threshold-and-dismiss.

### Chrome

- `uiVisible = false` on every entry into the reader; not persisted across sessions.
- **Top bar:** `Button(action: dismiss) { Image(systemName: "xmark") }` (left), `Text(book.title).lineLimit(1)` (center), nothing on the right.
- **Bottom strip:** `ProgressView(value: locator.totalProgression ?? 0)` plus `"\(percentInt)% • \(chapterLabel)"`. `chapterLabel = locator.title ?? "Chapter ?"`.
- Both bars respect safe areas so they sit clear of the Dynamic Island and home indicator.
- Reader body uses `ignoresSafeArea()` (existing behavior).

### Status bar

- Hidden while chrome is hidden; shown when chrome is visible.
- Implemented via `ReaderContainerVC.prefersStatusBarHidden` reading from a property the SwiftUI side toggles; transition animated through `setNeedsStatusBarAppearanceUpdate(animatedWithDuration:)` pattern.

## Data flow & state ownership

| State | Owner | Lifetime |
|---|---|---|
| `activeReader: ReaderRoute?` | `AppEnvironment` (`@Observable`) | App |
| `fontSizePct: Int` | `@AppStorage("reader.fontSizePct")` | App (persisted) |
| `uiVisible: Bool` | `ReaderView` `@State` | Per presentation |
| `fontHUD: Int?` | `ReaderView` `@State` | Per pinch |
| `currentLocator: Locator?` | `ReaderView` `@State` | Per presentation |
| `publication`, `initialLocator` | `ReaderView` `@State` (existing) | Per presentation |
| `ReadingProgress` | SwiftData (existing) | Persistent |
| Navigator internal page | `EPUBNavigatorViewController` | Per navigator instance |

**Single source of truth for font size:** `@AppStorage`. The navigator's preferences are a projection written via `updateUIViewController`. We never read the font size back from the navigator. The initial value is applied when the navigator is first instantiated (so a user who reads at 120 % keeps that on every open, not just after the first pinch).

**Why `AppEnvironment` owns `activeReaderBookID`:** two presentation sites (Home, Browse) need to open the reader. Hoisting state above both tab roots guarantees one reader at a time, app-wide, and lets `.fullScreenCover` live on `RootView` so the modal covers the tab bar. Replaces the existing `OpenReaderRoute` navigation destination in `BrowseRootView`, which is removed.

### Event flows

*Open:* tap → `env.openReader(bookID)` → `env.activeReader = ReaderRoute(id: bookID)` → `RootView` modal presents → existing `ReaderView` load logic runs unchanged.

*Page turn:* edge tap or arrow key → `goForward` / `goBackward(animated: false)` → navigator updates → `coordinator.locationDidChange` → existing `onLocatorChange` (sync upload) + `currentLocator` updated for the bottom strip.

*Pinch:* recognizer state machine above. SwiftUI re-renders `ReaderHost`; `updateUIViewController` applies preferences once on `.ended`.

*Center tap:* `onCenterTap` → `uiVisible.toggle()` → chrome fades; `setNeedsStatusBarAppearanceUpdate`.

*Dismiss (X / ESC / swipe):* all three call SwiftUI `dismiss()` → `ReaderView.onDisappear` → existing `flush()` to kosync (unchanged) → modal binding clears `env.activeReader`.

## Error handling

| Failure | Behavior |
|---|---|
| Readium clamps a font size outside its supported range | Silent no-op (user saw target in HUD). No error UI. |
| `goForward` / `goBackward` returns `false` (navigator not ready) | Ignore. No error UI. |
| `UIKeyCommand` doesn't fire (first responder lost) | `becomeFirstResponder()` in `viewWillAppear` + `scenePhase == .active`. Silent recovery. |
| `env.openReader` called while a reader is already open | No-op (guarded by `activeReader != nil` check). |
| Swipe-down false positive on diagonal scroll | Mitigated by distance + velocity sign + vertical-dominant check. If still problematic in QA: add `require(toFail:)` against Readium's pan recognizer. |

The existing `OpenError` paths and `DownloadingView` flow inside `ReaderView` are untouched.

## Testing strategy

### Unit (pure functions in `ReaderGestureHelpers.swift`)

Place tests in `iOSReaderTests/Views/Reader/`.

- `TapZoneClassifier.classify(x:width:)` — boundaries at `0.249`, `0.25`, `0.75`, `0.751` of width.
- `FontSizeStep.clamp(startPct:scale:)` — `scale = 1.0` is identity; scale `> 1` snaps up; bounds at 60 and 200; rounding at 0.5-step boundaries.
- `SwipeDismissPolicy.shouldDismiss(translation:velocity:)` — under threshold → false; horizontal-dominant → false; upward velocity → false; meets all three → true.

### Manual (device only)

- Pinch HUD fade timing.
- Status bar transition on chrome toggle.
- iPad keyboard: `←`, `→`, `ESC` in portrait + landscape, with and without chrome visible.
- Text selection still works in the center 50%.
- Swipe-down on the body dismisses; swipe-down on the visible top bar does not.
- Modal covers the tab bar (regression vs. current push presentation).

### Not retested

- `@AppStorage` persistence across cold launch.
- kosync flush on dismiss — covered by existing `SyncServiceTests`; pipeline unchanged.

## Risks

- **First-responder fragility for `UIKeyCommand`** — mitigated by the `viewDidAppear` + scene-phase recovery, but if Readium's WebViews install accessory views in some flow we haven't seen, keys could go quiet. Recovery is a single line; risk is low impact.
- **Gesture conflicts with Readium's recognizers** — Readium ships its own taps, long-presses (text selection), and pans. We disable Readium's tap-nav and use `hitTest` to pass long-presses through. If a regression surfaces, the fix is `require(toFail:)` between recognizers.
- **Modal stacking** — guarded by `openReader` being a no-op when one is already open.

## Open questions

None. Decisions captured during brainstorming:
- Presentation: `fullScreenCover`.
- Chrome: top (close + title) + bottom (read-only progress + chapter).
- Tap zones: 25 / 50 / 25.
- Font: global `@AppStorage`, 60 – 200 % in 10 % steps.
- Architecture: hybrid (UIKit input + SwiftUI chrome).
- Bottom strip: read-only.
- `⋯` button: dropped from v1.
