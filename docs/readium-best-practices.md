# Readium swift-toolkit best practices

Reference for working with `readium/swift-toolkit` 3.9+. The project-specific integration notes live in [`readium.md`](readium.md) — this doc covers general patterns, gotchas, and APIs you'll reach for repeatedly.

## Modules

The toolkit is split into small libraries. Take what you need:

| Module | Use for |
|--------|---------|
| `ReadiumShared` | Core types: `Publication`, `Locator`, `Link`, `Manifest`. Always required. |
| `ReadiumStreamer` | Open a file → produce a `Publication`. |
| `ReadiumNavigator` | Render a `Publication` (EPUB, PDF, CBZ, audio). |
| `ReadiumOPDS` | Parse OPDS 1/2 catalog feeds. |
| `ReadiumZIPFoundation` | EPUB-specific ZIP handling (separate package, used internally). |
| `ReadiumLCP` | DRM (requires proprietary `R2LCPClient.framework` from EDRLab). Not used here. |

In `project.yml:36-46` this app links `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`, `ReadiumOPDS`, and `ReadiumZIPFoundation`.

## Lifecycle: open → render

The full path from "file on disk" to "user reading a chapter":

```
File URL
  ↓  Streamer (open + parse)
Publication
  ↓  EPUBNavigatorViewController (render)
UIViewController
  ↓  UIViewControllerRepresentable bridge
SwiftUI body
```

### Opening with Streamer

```swift
let asset = FileAsset(file: FileURL(url: fileURL)!)
let publication = try await streamer.open(asset: asset, allowUserInteraction: false).get()
```

Streamer auto-detects format and uses the right parser. Always:

- Check `publication.conforms(to: .epub)` before instantiating an EPUB navigator.
- Hold the `Publication` for the lifetime of the reading session — closing it releases parser resources.

### Rendering with `EPUBNavigatorViewController`

```swift
// Kios/Views/Reader/ReaderContainerVC.swift
let config = EPUBNavigatorViewController.Configuration(
    preferences: makePreferences(),
    editingActions: EditingAction.defaultActions
)
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
```

The navigator is a `UIViewController`. Add it as a child of your container — don't try to embed it as a SwiftUI view directly.

## Bridging into SwiftUI

`UIViewControllerRepresentable` is the canonical pattern:

```swift
// Kios/Views/Reader/ReaderHost.swift
struct ReaderHost: UIViewControllerRepresentable {
    let publication: Publication
    let initialLocator: Locator?
    let pendingJump: Locator?
    let fontSizePct: Int
    let fontFamilyRaw: String
    var onLocatorChange: @Sendable (Locator) -> Void
    var onCenterTap: () -> Void
    ...

    func makeUIViewController(context: Context) -> UIViewController {
        if publication.conforms(to: .epub) {
            let vc = ReaderContainerVC(publication: publication, initialLocator: initialLocator)
            vc.update(fontSizePct: fontSizePct, fontFamilyRaw: fontFamilyRaw)
            vc.onLocatorChange = onLocatorChange
            ...
            return vc
        }
        return errorController("Only EPUB is supported.")
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let container = uiViewController as? ReaderContainerVC else { return }
        container.update(fontSizePct: fontSizePct, fontFamilyRaw: fontFamilyRaw)
        // Re-bind callbacks each update — SwiftUI may have re-created closures.
        container.onLocatorChange = onLocatorChange
        ...
    }
}
```

Three things to know:

1. **Don't create the navigator inside the SwiftUI view** — make a UIKit container VC. The container owns the input layer (gestures, hardware keys, status bar) and outlives `updateUIViewController` invocations.
2. **Re-bind callbacks on every update.** SwiftUI re-creates closures on each render.
3. **Dedupe state changes inside the container.** SwiftUI re-renders are cheap, but bridging into the WKWebView CSS pipeline isn't — guard against redundant work.

```swift
// Kios/Views/Reader/ReaderContainerVC.swift
func update(fontSizePct: Int, fontFamilyRaw: String) {
    let sizeChanged = self.fontSizePct != fontSizePct
    let familyChanged = self.fontFamilyRaw != fontFamilyRaw
    if sizeChanged { self.fontSizePct = fontSizePct }
    if familyChanged { self.fontFamilyRaw = fontFamilyRaw }
    if sizeChanged || familyChanged { applyPreferences() }
}
```

## Locators

A `Locator` is Readium's stable position descriptor — independent of pagination, font size, or device. Each carries:

- `href` — the chapter file inside the publication.
- `locations.progression` — 0…1 within the chapter.
- `locations.totalProgression` — 0…1 across the publication.
- `locations.position` — integer "page" index (stable per publication, not per render).
- Optionally: `cssSelector`, `partialCfi`, `position` — extra hints.

### Persisting position

```swift
// EPUBNavigatorDelegate
func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    let json = try? locator.jsonString()
    progress.locatorJSON = json
}
```

Store the JSON string. Restore with:

```swift
let locator = try? Locator(jsonString: stored.locatorJSON)
let nav = try EPUBNavigatorViewController(publication: publication, initialLocation: locator)
```

This codebase wires this through `SyncService.bufferLocator` → SwiftData → server (`Kios/Services/SyncService.swift`).

## Input layer

Readium ships an idiomatic input observer pattern. Use it instead of layering custom `UIGestureRecognizer`s on the navigator view — those will conflict with WKWebView's own gesture handling.

```swift
// Kios/Views/Reader/ReaderContainerVC.swift
private func installInputObservers() {
    guard let nav = navigator else { return }

    let dna = DirectionalNavigationAdapter(
        pointerPolicy: .init(types: [.mouse, .touch]),
        onNavigation: { [weak self] in self?.onPageTurn?() }
    )
    dna.bind(to: nav)
    directionalNavigationAdapter = dna           // ← retain!

    nav.addObserver(.activate { [weak self] _ in
        self?.onCenterTap?()
        return true
    })

    nav.addObserver(.key(.escape) { [weak self] in
        self?.onDismissRequested?()
        return true
    })
}
```

### Critical: retain the `DirectionalNavigationAdapter`

In Readium 3.9 the adapter's observer closures capture `self` *weakly*. If you drop the adapter after `bind(to:)`, it deinits, and edge-tap page turns silently stop working. **Store a strong reference**:

```swift
private var directionalNavigationAdapter: DirectionalNavigationAdapter?
```

This is documented in the codebase via the comment at `ReaderContainerVC.swift:49`.

### Observer ordering

`DirectionalNavigationAdapter` and `.activate` observers both fire on taps. The adapter handles edge taps; the activate observer handles center taps.

**Bind the adapter first.** It evaluates whether the tap is on an edge, consumes the event if so, and lets it propagate otherwise. The activate observer's `return true` then stops propagation.

### Custom gestures (the exception)

The only custom `UIGestureRecognizer` in this codebase is the pinch — Readium has no pinch primitive. See `Kios/Views/Reader/ReaderInputHandlers.swift`.

## EPUBPreferences

Configures rendering: font, theme, columns vs scroll, line height. Submit a fresh struct each time:

```swift
var prefs = EPUBPreferences()
prefs.fontSize = 1.20                              // 1.0 = 100%
prefs.fontFamily = FontFamily(rawValue: "Iowan Old Style")
prefs.theme = .light                               // .light, .dark, .sepia
prefs.scroll = false                               // paginated
prefs.columnCount = .auto

navigator.submitPreferences(prefs)
```

Readium dedupes idempotent submissions, but it's cheap to skip the call entirely if nothing changed (see "dedupe state changes" above).

### Font sizing

The codebase exposes pinch-to-resize via percent (`fontSizePct`):

```swift
prefs.fontSize = Double(fontSizePct) / 100.0
```

`@AppStorage("reader.fontSize")` round-trips through the SwiftUI view → `ReaderHost.update` → container → preferences → WKWebView.

### Custom fonts

Use the CSS family name verbatim:

```swift
prefs.fontFamily = FontFamily(rawValue: "Iowan Old Style")   // system-installed
prefs.fontFamily = FontFamily(rawValue: "Newsreader")        // app-bundled (when shipped)
```

For app-bundled fonts, register the TTF in your Info.plist's `UIAppFonts` and bundle the file. Readium passes the family name to WebKit's `@font-face` resolution.

## Delegate

`EPUBNavigatorDelegate` (extends `NavigatorDelegate`) handles position changes, link presses, presentation changes:

```swift
extension ReaderContainerVC: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocatorChange?(locator)
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        UIApplication.shared.open(url)
    }
}
```

Position events fire on the **main actor**.

## OPDS

For server catalogs:

```swift
let feed = try await OPDSParser.parseURL(url: feedURL).get()
for publication in feed.publications {
    print(publication.metadata.title)
}
```

This codebase wraps OPDS calls in `Kios/Catalog/OPDS/OPDSClient.swift` and exposes a higher-level `CatalogBackend` protocol.

## Common gotchas

| Symptom | Cause | Fix |
|---------|-------|-----|
| Edge taps don't turn pages | `DirectionalNavigationAdapter` not retained | Store as a property |
| EPUB reflows on chrome toggle | Status bar visibility changes `safeAreaInsets` | `prefersStatusBarHidden: true` always — see `ReaderContainerVC.swift:103` |
| Body text bleeds under bottom bar | Blanket `.ignoresSafeArea()` | `.ignoresSafeArea(edges: [.top, .horizontal])` + `.safeAreaInset(edge: .bottom) { … }` |
| Repeated jumps on SwiftUI re-render | `applyPendingJump` not deduped | Dedupe by `Locator.jsonString` — see `ReaderContainerVC.swift:135` |
| First open takes ~1GB SPM resolution | Readium deps are large | Cache `~/Library/Developer/Xcode/DerivedData/` |
| Non-EPUB files crash navigator | Wrong navigator for format | Check `publication.conforms(to: .epub)` before instantiating |

## Format support

EPUB (reflowable + fixed) is the v1 target. The other formats need additional plumbing:

- **PDF** — needs `PDFNavigatorViewController` and an HTTP server adapter for resources (Readium ships a built-in one but you have to opt in).
- **CBZ** — `CBZNavigatorViewController`.
- **Audiobooks** — `AudioNavigator` is chromeless; you build your own player UI.

For v1, the codebase shows a polite error label for non-EPUB:

```swift
// Kios/Views/Reader/ReaderHost.swift
return errorController(
    "Only EPUB is supported in this version.\n"
  + "PDF and CBZ require an HTTP server adapter."
)
```

## Patterns from this codebase

### Container VC owns input, not SwiftUI

`ReaderContainerVC` (UIKit, `@MainActor`) is the source of truth for input handlers, navigator preferences, and the navigator instance. `ReaderHost` (SwiftUI) is a thin bridge — it carries inputs in (font size, locator) and callbacks out (locator change, taps).

This split exists because:

- Readium's input API needs a `UIViewController` to bind to.
- SwiftUI re-renders are too cheap to trigger CSS reflows on each one.
- A long-lived UIKit container can hold mutable state cleanly without `@State` churn.

### Selection probe pattern

SwiftUI gesture handlers sometimes need to ask the navigator "is text currently selected?" synchronously. The container exposes a reference-typed probe:

```swift
// Kios/Views/Reader/ReaderHost.swift
@MainActor
final class ReaderSelectionProbe {
    var hasSelection: () -> Bool = { false }
}

selectionProbe.hasSelection = { [weak vc] in vc?.hasCurrentSelection() ?? false }
```

The closure captures `[weak vc]` so the probe never extends the container's lifetime.

## See also

- [`readium.md`](readium.md) — codebase-specific integration notes (input pattern, locator persistence).
- [`readium-followups.md`](readium-followups.md) — open issues tracked against upstream.
- [`swiftui-and-hig.md`](swiftui-and-hig.md) — safe-area handling for the reader chrome.
- Readium docs (in-tree): `https://github.com/readium/swift-toolkit/tree/main/docs`.
