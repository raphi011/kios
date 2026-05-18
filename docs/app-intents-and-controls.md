# App Intents + Controls + Widgets

Reference for `AppIntents`, iOS 18 Control Widgets, Siri Shortcuts, and the architecture that lets the main app and the extension share state.

The extension target in this codebase: `KiosControls/` (see `project.yml:78-101`). It's an `app-extension` targeting iOS 18.

## Mental model

An App Intent is a verb your app exposes to the system. iOS 16+ uses them for Shortcuts; iOS 17 added Action Button; iOS 18 added Control Center via Control Widgets. One intent, many surfaces.

```
            ┌─────────────────────────────────────┐
            │  AppIntent (OpenMostRecentBookIntent)│
            └─────────────────────────────────────┘
                              │
       ┌──────────────────────┼────────────────────┐
       ▼                      ▼                    ▼
  AppShortcuts          Action Button       ControlWidget (iOS 18)
  (Siri / Spotlight)                        (Control Center)
```

## Targets and processes

This is the part most tutorials skip:

- **App** (`Kios.app`) — the main process. Owns the SwiftData store on disk.
- **Extension** (`KiosControls.appex`) — a separate binary, loaded by the system when Control Center renders your control. Limited memory, limited lifetime.
- **AppIntents library** — *the intent code itself* gets compiled into both binaries. The system decides where to run it based on `openAppWhenRun` and the entitlements.

The extension and the app are **separate processes**. They cannot share in-memory state. They share via:

- The SwiftData store (same file URL).
- App Groups (UserDefaults, files).
- Keychain.

## Defining an intent

```swift
// Kios/Intents/OpenMostRecentBookIntent.swift
struct OpenMostRecentBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Most Recent Book"
    static let description = IntentDescription(
        "Opens the book you were last reading.",
        categoryName: "Reading"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try ModelContainer.kios()
        let context = ModelContext(container)
        guard let book = MostRecentBookSelector.pick(in: context) else {
            throw OpenMostRecentBookError.noBook
        }
        BookOpenCoordinator.shared.request(book.id)
        return .result()
    }
}
```

Key fields:

| Field | Use |
|-------|-----|
| `title` | Shown in Shortcuts gallery and Spotlight. `LocalizedStringResource`. |
| `description` | Longer description with optional `categoryName` for the gallery. |
| `openAppWhenRun` | `true` → system foregrounds the app; `perform()` runs in app process. `false` → runs in extension. |
| `isDiscoverable` | Default `true`. Set `false` to hide from Shortcuts/Spotlight. |
| `parameterSummary` | Custom UI for parameters in the Shortcut editor. |

### `openAppWhenRun: true` vs `false`

- **`true`**: tap triggers a system handoff to your app. `perform()` runs in-app, so it can update SwiftUI state directly. Use this when the intent needs to navigate.
- **`false`**: runs entirely in the extension. Useful for intents that just toggle state, fire a notification, or push data through `WidgetCenter.shared.reloadAllTimelines()`.

This codebase uses `true` because "Continue Reading" needs to push the user into the reader UI.

### Errors

```swift
enum OpenMostRecentBookError: Error, CustomLocalizedStringResourceConvertible {
    case noBook
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noBook: "No book to open yet."
        }
    }
}
```

`CustomLocalizedStringResourceConvertible` provides the message the system shows in the Shortcuts UI. Plain `Error` types display a generic failure message.

## App Shortcuts (Siri + Spotlight)

```swift
// Kios/Intents/OpenMostRecentBookIntent.swift
struct KiosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMostRecentBookIntent(),
            phrases: [
                "Open my book in \(.applicationName)",
                "Continue reading in \(.applicationName)",
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book.fill"
        )
    }
}
```

`AppShortcutsProvider` is auto-discovered by the system. **Provide multiple phrases** — Siri picks based on user intent and grammar. Use `\(.applicationName)` so the phrase localizes naturally.

The `AppShortcut`s show up in:

- Siri ("Hey Siri, open my book in Kios")
- Spotlight search results
- Shortcuts.app (the gallery)
- Action Button picker

## Control Widgets (iOS 18)

```swift
// KiosControls/ContinueReadingControl.swift
struct ContinueReadingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.raphi011.kios.Controls.ContinueReading"
        ) {
            ControlWidgetButton(action: OpenMostRecentBookIntent()) {
                Label("Continue Reading", systemImage: "book.fill")
            }
        }
        .displayName("Continue Reading")
        .description("Opens the book you were last reading.")
    }
}
```

And the bundle:

```swift
// KiosControls/KiosControlsBundle.swift
@main
struct KiosControlsBundle: WidgetBundle {
    var body: some Widget {
        ContinueReadingControl()
    }
}
```

### Static vs dynamic configurations

| Configuration | Use when |
|---------------|----------|
| `StaticControlConfiguration` | No user-configurable parameters. |
| `AppIntentControlConfiguration` | User picks parameters when adding the control (e.g. "which book to open?"). Backed by `ControlConfigurationIntent`. |

### Control kinds

- `ControlWidgetButton(action: someIntent)` — fires an intent.
- `ControlWidgetToggle(_:isOn:action:)` — bound to a stateful intent (`SetValueIntent`).
- `ControlWidgetView` — embedded glanceable info (rare, mostly Apple use cases).

### Adding to Control Center

The user must:

1. Long-press Control Center.
2. Tap **Add a Control**.
3. Pick from the gallery.

There's no programmatic way to install a control. Document the steps in your release notes.

## Sharing state between app and extension

The extension is a separate process. Three options:

### 1. Shared SwiftData store

The cleanest path when you already have a SwiftData model. Both binaries instantiate the same `ModelContainer`:

```swift
// Kios/App/ModelContainerFactory.swift
extension ModelContainer {
    static func kios() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 Bookmark.self, Source.self
        )
    }
}
```

The extension calls `ModelContainer.kios()` — same database file, same schema. SwiftData synchronizes through the file system.

**Critical**: the extension needs source-level access to every `@Model` class. See `project.yml:84-99` — `KiosControls.sources` explicitly lists every model file. Forgetting one causes a runtime crash when the extension tries to instantiate the container.

There's a project memory for this:

> `KiosControls` needs explicit Models entries — new `Kios/Models/*.swift` used by `ModelContainerFactory` must be added to `project.yml`'s `KiosControls.sources` list

### 2. App Groups (UserDefaults / files)

For lighter state (last-known values, flags), use an App Group:

```swift
let defaults = UserDefaults(suiteName: "group.com.raphi011.kios")!
defaults.set("abc", forKey: "lastReadBookID")
```

Set up the App Group in both targets' entitlements and provisioning. Used for: small flags, counters, tiny state the extension can read without spinning up SwiftData.

### 3. Keychain

For secrets. Keychain access groups work the same as App Groups but for secure storage. Set `kSecAttrAccessGroup`.

## Inter-process communication when the app foregrounds

`openAppWhenRun: true` foregrounds the app and triggers `perform()` in the app process. But how does the intent tell the running app "open *this* book"?

This codebase uses a singleton mailbox:

```swift
// Kios/App/BookOpenCoordinator.swift (sketch)
@MainActor
final class BookOpenCoordinator: ObservableObject {
    static let shared = BookOpenCoordinator()
    @Published private(set) var pendingBookID: UUID?

    func request(_ id: UUID) { pendingBookID = id }
    func consume() -> UUID? {
        defer { pendingBookID = nil }
        return pendingBookID
    }
}
```

Then `RootView` observes:

```swift
// Kios/Views/RootView.swift
@State private var coordinator = BookOpenCoordinator.shared

.onChange(of: coordinator.pendingBookID) { _, newValue in
    guard newValue != nil, let id = coordinator.consume() else { return }
    env.openReader(id)
}

.onAppear {
    // Cold launch: intent may have set pendingBookID before RootView mounted.
    if let id = coordinator.consume() { env.openReader(id) }
}
```

Two paths matter:

- **Warm launch**: app is running, intent fires, sets `pendingBookID`, `.onChange` reacts.
- **Cold launch**: app is dead, intent triggers launch, `perform()` runs early, sets `pendingBookID`, `RootView.onAppear` consumes it.

Both paths drain through the same coordinator. Idempotent via `consume()` setting back to nil.

## Anti-patterns

- **Reaching into the app from the extension via singletons.** Extensions are separate processes. `MyAppDelegate.shared` doesn't exist in the extension.
- **Sharing in-memory caches.** A `static let cache = NSCache(...)` exists in both processes, but the contents are separate.
- **Heavy work in `perform()` for `openAppWhenRun: false` intents.** Extensions are killed quickly. Aim for <100ms.
- **Forgetting to add new `@Model` files to the extension's `sources`.** Causes runtime crashes (the container fails to instantiate). See the project memory.

## Common pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Extension can't find a model class | Crash on `ModelContainer.kios()` | Add the file to `KiosControls.sources` in `project.yml` |
| App Group entitlement missing | UserDefaults reads/writes are silent no-ops | Verify entitlements in both targets |
| Intent fires but app doesn't react | Coordinator's `@Published` not observed | Check `.onChange` is on a mounted view |
| Cold launch loses the request | `RootView.onAppear` not draining | Always drain on both `.onChange` and `.onAppear` |

## Patterns from this codebase

### Single source of truth for the schema

`ModelContainer.kios()` is the only place that lists every `@Model` class. The app calls it, the extension calls it, tests call `kiosInMemory()`. Schema changes happen in one place.

### Mailbox singleton over notifications

`BookOpenCoordinator.shared` is a singleton with `@Published` state. Cleaner than `NotificationCenter` for one-shot UI handoffs because:

- It's typed (no `userInfo: [String: Any]` casting).
- It survives the cold-launch race (state is on disk-bound singleton, drained on appear).
- It's observable from SwiftUI directly.

## See also

- [`swiftdata.md`](swiftdata.md) — sharing a container across processes.
- `project.yml:84-99` — the canonical extension `sources` list.
- Apple docs: `https://developer.apple.com/documentation/appintents`
- WWDC 24 "Bring your app to Siri" + "Extend your app's controls across the system".
