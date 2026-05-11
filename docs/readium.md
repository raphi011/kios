# Readium Integration Notes

How this app integrates with the [readium/swift-toolkit] (Readium 3.x). Living document — update when patterns change or upstream issues close.

[readium/swift-toolkit]: https://github.com/readium/swift-toolkit

## Stack at a glance

- **Toolkit:** `swift-toolkit` 3.8.0 (SPM, async/await API).
- **Hosting:** SwiftUI app, UIKit container (`ReaderContainerVC`) holds `EPUBNavigatorViewController` as a child VC. Bridged to SwiftUI via `ReaderHost: UIViewControllerRepresentable`.
- **Input layer:** Readium's canonical `InputObservable` API — `DirectionalNavigationAdapter` for edge taps + arrow keys, `.activate` observer for center taps, `.key(.escape)` for dismiss. Pinch is the only custom `UIGestureRecognizer` because Readium has no pinch primitive.
- **Format:** EPUB only in v1. Non-EPUB publications surface an error label.
- **Locator persistence:** Delegate's `locationDidChange` → `Locator.jsonString` → SwiftData (`ReadingProgress`). Buffered + flushed on scene change.

## Input layer

We follow the canonical pattern from the toolkit's `TestApp/Sources/Reader/Common/VisualReaderViewController.swift`:

```swift
// Bind the adapter FIRST so its tap observer sees events before ours.
DirectionalNavigationAdapter(
    pointerPolicy: .init(types: [.mouse, .touch])
).bind(to: nav)

// Center taps (fires only when the adapter returned false — i.e. tap
// wasn't on an edge).
nav.addObserver(.activate { [weak self] _ in
    self?.onCenterTap?()
    return true
})

// Escape dismisses the reader.
nav.addObserver(.key(.escape) { [weak self] in
    self?.onDismissRequested?()
    return true
})
```

Wired in `ReaderContainerVC.installInputObservers()`.

### Why this and not a custom UITapGestureRecognizer

We had a `UITapGestureRecognizer` on the container view, used `cancelsTouchesInView = true`, and bridged through `UIGestureRecognizerDelegate.shouldRecognizeSimultaneouslyWith` to coexist with WKWebView's recognizers. That worked but had several drawbacks:

- Direction-blind: tapped-left always called `goBackward`, tapped-right always `goForward`. Wrong for RTL EPUBs (Arabic/Hebrew/vertical Japanese) where `goLeft` = forward.
- Fragile interaction with WKWebView's own gesture stack (tap highlight, callout, selection).
- The toolkit's SwiftUI guide explicitly warns: *"Avoid using SwiftUI touch modifiers, as they will prevent the user from interacting with the book."* The UIKit-recognizer equivalent has similar pitfalls.

`DirectionalNavigationAdapter` handles direction-awareness via `nav.goLeft`/`nav.goRight`, respects reading progression, and ignores edge taps while scrolling (`ignoreWhileScrolling: true` default). It also folds arrow-key navigation into the same abstraction via its `KeyboardPolicy` (default: arrows + space).

### Edge thresholds

Adapter defaults: 30 % of viewport width per edge, minimum 80 pt. We use the defaults. Previous custom impl was 25 % per edge. Override via `PointerPolicy(horizontalEdgeThresholdPercent: 0.25, minimumHorizontalEdgeSize: 80)` if needed.

### First-responder

`InputObservableViewController` (the navigator's base class) calls `becomeFirstResponder()` in its own `viewDidAppear`. We deliberately do **not** override `viewDidAppear` or `canBecomeFirstResponder` on the container — the navigator must be first responder for `pressesBegan`/`pressesChanged` to forward to the input observers. UIKeyCommands defined on the container would *not* work today (we removed them), but if reintroduced they'd still fire via responder-chain discovery from the navigator upward.

### Pinch

`ReaderInputHandlers` attaches a single `UIPinchGestureRecognizer` to the container view. Maps cumulative scale onto a 10-step font-size percent (`FontSizeStep.clamp`), shows a HUD on `.began`/`.changed`, commits on `.ended` via `EPUBPreferences(fontSize:)`. `UIGestureRecognizerDelegate.shouldRecognizeSimultaneouslyWith` returns `true` so we coexist with WKWebView's own pinch recognizer. `cancelsTouchesInView = false` — we don't want to cancel touches the navigator's tap observer also wants to see.

## Preferences

`EPUBNavigatorViewController.Configuration` is built with `EPUBPreferences(fontSize: Double(fontSizePct) / 100.0)` at construction time. Subsequent changes go through `nav.submitPreferences(prefs)`.

Caveat: `submitPreferences` does not always cleanly re-layout for changes that affect pagination (`spread`, `columnCount`, `scroll`). The inkyomi-ios project rebuilds the navigator preserving `currentLocation` for those. We only change `fontSize` today, so this hasn't bitten us.

## Locator persistence

```
EPUBNavigatorDelegate.navigator(_:locationDidChange:)
  → Task @MainActor → onLocatorChange?(locator)
  → SwiftUI side: SyncService.bufferLocator(...) → SwiftData
```

Buffered writes; flushed on `scenePhase != .active` and on `onDisappear`. See `SyncService`.

## Custom CSS / script injection

`EPUBNavigatorDelegate.navigator(_:setupUserScripts:)` hands you the `WKUserContentController` the navigator uses for its WebViews. Add `WKUserScript`s here — they run for every EPUB resource (every chapter is its own document).

This is the **only** clean, public Readium 3.x API for runtime injection. `EPUBNavigatorViewController.Configuration` has no CSS field. Tracked: [readium/swift-toolkit#123] (planned, not shipped — would add `Injectable` API or `HTMLInjectionContentFilter`). For now, `setupUserScripts` + JS that appends a `<style>` tag is the workaround.

[readium/swift-toolkit#123]: https://github.com/readium/swift-toolkit/issues/123

We currently inject nothing (see "Page-turn flicker" below — our earlier probe didn't help, removed).

## Known issues affecting us

### Page-turn flicker (Readium [#737])

**Symptom:** Brief translucent rectangles flash on tap-to-turn-page, more visible on iPad. Only on tap, not arrow keys (same code path, but page-content-dependent rendering).

**Cause:** `WKWebView.scrollView.setContentOffset(_, animated: false)` inside `EPUBReflowableSpreadView` produces a one-frame UIKit↔WebKit render desync. Mickael Menu (maintainer):

> "The glitch happens when using a native Swift scroll with `animated: false` in a `WKWebView`. … No glitch when using JavaScript APIs to scroll — e.g. `window.scrollTo({ behavior: 'smooth' })`."

**Fix:** PR [#750] (merged 2026-03-19) replaces `setContentOffset` with `evaluateScript("window.scrollBy({ behavior: 'instant' })")`. Our pin (3.8.0, tagged 2026-03-10) is **9 days too old** — fix lands in 3.9.0. Bump `Package.resolved` when 3.9.0 releases (or pin `main` past commit `f7d10d2` to get it now).

**Probes tried:** Injected `* { -webkit-tap-highlight-color: transparent !important; }` via `setupUserScripts` — no effect. Confirmed it's not a WebKit tap-highlight issue.

**Residual:** Even after #750, a smaller cross-resource (chapter-boundary) flash remains. Mickael considers it inherent to nesting `WKWebView` in a `UIScrollView`. Workaround if it ever matters: snapshot-and-overlay during transition (user `7enChan` shipped this in their app — see #737 thread).

[#737]: https://github.com/readium/swift-toolkit/issues/737
[#750]: https://github.com/readium/swift-toolkit/pull/750

### Other tracked issues worth knowing

| # | What | Status |
|---|---|---|
| [#699](https://github.com/readium/swift-toolkit/issues/699) | Paging during text-selection drag scrolls past page boundary | Won't fix; workaround = inject `overflow: hidden` on `html` via JS layer |
| [#138](https://github.com/readium/swift-toolkit/issues/138) | Top margin shifts when toggling navigation bar | Open — relevant to our immersive chrome |
| [#466](https://github.com/readium/swift-toolkit/issues/466) / [#509](https://github.com/readium/swift-toolkit/issues/509) | Custom `EditingAction` on iOS 17/18 (UIMenuController deprecation) | Workaround: put selectors on parent VC so responder chain finds them. Relevant if we ever add highlight/note actions |
| [#373](https://github.com/readium/swift-toolkit/issues/373) | Larger-text accessibility setting pushes text under nav bar | Open |
| [#521](https://github.com/readium/swift-toolkit/issues/521) | Disable horizontal swiping in vertical scroll mode | Open |

## OSS reference projects

In rough order of how relevant they are to our stack:

- **[readium/swift-toolkit `TestApp`](https://github.com/readium/swift-toolkit/tree/main/TestApp)** — canonical reference. `VisualReaderViewController` is the input-setup pattern we copied.
- **[stevenzeck/ReadiumSwiftTestApp](https://github.com/stevenzeck/ReadiumSwiftTestApp)** — pure-SwiftUI port of TestApp with SwiftData. Closest to our stack. Lets the toolkit's `DirectionalNavigationAdapter` handle edges; takes only center tap.
- **[morrigangirl/inkyomi-ios](https://github.com/morrigangirl/inkyomi-ios)** — near-identical SwiftUI + UIKit-container architecture. Notable patterns:
  - No `UITapGestureRecognizer` at all — uses delegate's `navigator(_:didTapAt:)` with `point.x` thirds.
  - Rebuilds navigator (`reloadNavigator()`) for layout-changing prefs (`spread`, `columnCount`), preserving `currentLocation`. `submitPreferences` alone is unreliable there.
  - `publisherStyles = false` to force theme/font overrides through.
- **[classicsc/MaruReader](https://github.com/classicsc/MaruReader)** — most sophisticated gesture overlay. Uses two narrow `Color.clear` strips (margin-width) on left/right with `DragGesture`, leaving the center column fully transparent so WKWebView gets normal text selection. Useful pattern if we ever need richer side gestures without disturbing selection.
- **[Stanza-Redux](https://github.com/Stanza-Redux/Stanza-Redux)**, **[AudioBooth](https://github.com/AudioBooth/AudioBooth)** (audiobookshelf companion, 260★), **[Auread](https://github.com/jimjatt1999/Auread)** — additional Readium 3.x consumers worth grepping when stuck.

## Outstanding considerations

- **Bump swift-toolkit to 3.9.0** when released — closes #737.
- **RTL EPUBs:** now correctly direction-aware thanks to `DirectionalNavigationAdapter.goLeft`/`goRight`. Worth testing with an Arabic / Hebrew / vertical-Japanese sample.
- **Editing actions** (highlight, note, dictionary lookup): if added, ensure selectors live on `ReaderContainerVC` (parent VC) so the responder chain finds them — see #466/#509.
- **Layout-changing prefs:** if we add `spread` / `columnCount` toggles, plan to rebuild the navigator preserving `currentLocation` rather than `submitPreferences` alone.
