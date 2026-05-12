# Readium swift-toolkit — deferred adoption notes

Improvements available in `readium/swift-toolkit` (3.0 → 3.9.0 surveyed) that we've decided **not** to adopt yet, with notes on when they'd start paying off. Pinned for a future session so we don't have to re-do the survey.

## In-scope but deferred

### `ViewportObservingNavigator` / `viewportDidChange` (3.9.0)

`EPUBNavigatorViewController` now conforms to `ViewportObservingNavigator`, exposing:

```swift
public protocol ViewportObservingNavigator: VisualNavigator {
    var viewport: NavigatorViewport? { get }
}
```

`NavigatorViewport` carries the visible reading-order resources, a `progression: ClosedRange<Double>`, and an optional `positions: ClosedRange<Int>` for the visible page-list slice.

**Why deferred**: we already derive everything we need from `Locator` and the cached `positions()` list — current chapter, scrub source, page count. Adopting the viewport API now would be a parallel state holder with no new UX. Pick this up when we have a feature that needs the structured "what's currently visible" data — typical examples: a page X/Y indicator, a multi-resource preview for fixed-layout EPUBs, or analytics that care about resource bounds.

**Entry point**: `ReaderContainerVC` would gain `ViewportObservingNavigatorDelegate` conformance with a `navigator(_:viewportDidChange:)` implementation.

### Decoration API (3.0+, refined through 3.9)

`EPUBNavigatorViewController.Configuration` accepts `decorationTemplates`, and the navigator implements `DecorableNavigator` for runtime decoration application via `apply(decorations:in:)`. Powers highlights, persistent bookmarks, search-result rendering — anything that visually annotates the EPUB content without modifying it.

**Why deferred**: no annotation UX in v1.

**Entry point**: `EPUBPreferences` + a SwiftData model for stored decorations + a SwiftUI gesture to create them. The Readium guide at `docs/Guides/Navigator/Decorator.md` (in the toolkit) is the reference.

### Selection events (`SelectableNavigatorDelegate`)

Readium already calls our delegate (we conform to `SelectableNavigatorDelegate` implicitly through `EPUBNavigatorDelegate`), but we don't implement `navigator(_:didSelect:)`. The event carries the selection's locator and the user-selected text range.

**Why deferred**: no quote-share, no dictionary lookup, no "highlight selection" UX.

**Entry point**: implement `navigator(_:didSelect:)` and surface a context menu. Combines naturally with decorations (#2) for persistent highlights.

### `ContentSearchService` (3.9.0)

New SearchService implementation using Readium's Content API. Searches across resources for a query, returns locators for each match. Works for EPUB and (newly in 3.9) PDF.

**Why deferred**: no in-book search feature.

**Entry point**: `Publication.findService(SearchService.self)?.search(query:)` returns an async iterator. Wire to a SwiftUI search field; render results as a list of locators with surrounding text from `Locator.text.highlight`.

### `PointerEvent.targetElement` (3.9.0, `@_spi(ExperimentalTargetElement)`)

The EPUB navigator now populates `PointerEvent.targetElement` with information about what the user tapped — element type, attributes, location. Currently used in the Readium Playground for image-zoom. Behind an SPI marker, so it requires `@_spi(ExperimentalTargetElement) import ReadiumNavigator`.

**Why deferred**: experimental + we don't have a feature that needs per-tap target. Once stable, could replace some of our gesture plumbing for more accurate hit-testing.

**Entry point**: `EPUBNavigatorDelegate` reads `event.targetElement` from `.activate` / `.tap` observer events. Useful when adding image preview, footnote popovers, or link-tap routing that needs DOM context.

### `setupUserScripts` delegate hook

`EPUBNavigatorDelegate.navigator(_:setupUserScripts:)` lets us add `WKUserScript` to each EPUB resource webview. Companion `WKScriptMessageHandler` registration via the standard WKUserContentController API.

**Why deferred**: not needed today — `firstVisibleElementLocator()` covers our one DOM-introspection need (the koboSpan id at top of viewport). Pick this up if we ever need bespoke JS — e.g., custom annotation rendering, in-page TOC scroll markers, or DOM-mutation listeners.

### `DragPointerObserver` (3.6.0)

Recognizes drag gestures via the new `InputObserving` API. Could replace our SwiftUI `DragGesture` for swipe-down dismiss if we want consistency with how taps and key events flow through the navigator.

**Why deferred**: SwiftUI's `DragGesture` is working fine. The Readium-native path is cleaner architecturally but the migration has no behavior payoff.

## Already adopted in v1

For reference, the API surface we DO consume:

- `EPUBNavigatorViewController` (core).
- `EPUBNavigatorDelegate.navigator(_:locationDidChange:)` — sync layer's primary event.
- `EPUBNavigatorViewController.firstVisibleElementLocator()` — exact koboSpan extraction.
- `VisualNavigatorDelegate.navigatorContentInset(_:)` — stable insets across chrome toggle.
- `DirectionalNavigationAdapter` with `onNavigation:` callback — edge-tap navigation + auto-hide chrome.
- `.activate` and `.key(.escape)` observers — chrome toggle + dismiss.
- `EPUBNavigatorViewController.go(to:options:)` — `pendingJump` cross-device navigation.
- `EPUBNavigatorViewController.submitPreferences(_:)` — runtime font size.
- `Publication.positions()` + `Publication.tableOfContents()` — scrub bar + chapter resolution.
- `Locator` / `JSONValue(jsonString:)` / `Locator(json:)` — locator round-trips.
- `EPUBPreferences(fontSize:)` — pinch-to-zoom font scaling.

## Convention

When a session adopts a deferred item, **delete the entry above** and add it to the "Already adopted" list. Keeps the deferred list as a working catalog, not a museum.
