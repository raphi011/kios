# SwiftUI + iOS HIG best practices

Reference for SwiftUI under iOS 17+ and Apple's Human Interface Guidelines. Targets `iOS 17.0` (see `project.yml:9`); the Controls extension targets iOS 18 (`project.yml:81`).

The codebase already has a strong design system in `Kios/Views/Editorial/`. This doc covers SwiftUI state, layout, and HIG essentials — refer to `EditorialTheme.swift` and `EditorialComponents.swift` for the project's tokens.

## State management primitives (iOS 17+)

| Property | Use when |
|----------|----------|
| `@State` | View-local value state. Mark `private`. |
| `@Bindable` | Binding `$model.foo` for an `@Observable` reference type. |
| `@Binding` | Two-way value bridge passed from a parent. |
| `@Observable` class | Shared reference-typed model. Replaces `@ObservableObject` / `@Published`. |
| `@Environment(Type.self)` | Object-typed environment injection (typesafe replacement for `@EnvironmentObject`). |
| `@Environment(\.keyPath)` | System values (`\.scenePhase`, `\.modelContext`, `\.colorScheme`). |
| `@Query` | Live SwiftData fetch. See [`swiftdata.md`](swiftdata.md). |
| `@AppStorage` | UserDefaults-backed value state. Triggers redraws on change. |
| `@SceneStorage` | Per-scene state restoration. |

### Rule of thumb

- Reach for `@State` first. Lift to `@Observable` only when multiple views need the same instance.
- Prefer `@Environment(Type.self)` over `@EnvironmentObject` (legacy in iOS 17+).
- `@StateObject` and `@ObservedObject` are legacy — use `@State` + `@Observable` instead.

### From this codebase

```swift
// Kios/App/KiosApp.swift
@main
struct KiosApp: App {
    @State private var environment: AppEnvironment   // owns lifetime

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
                .environment(\.modelContext, environment.modelContext)
        }
    }
}

// Kios/Views/RootView.swift
struct RootView: View {
    @Environment(AppEnvironment.self) private var env  // injected reference
    @Environment(\.scenePhase) private var scenePhase  // system value
    @State private var selectedTab: Int = 0
    @State private var coordinator = BookOpenCoordinator.shared

    var body: some View {
        @Bindable var env = env                         // re-derive Bindable

        TabView(selection: $selectedTab) { ... }
            .onChange(of: scenePhase) { _, newPhase in ... }
            .fullScreenCover(item: $env.activeReader) { route in ... }
    }
}
```

Notes:

- `@State private var environment: AppEnvironment` owns the env across the app's lifetime.
- `@Environment(AppEnvironment.self)` reads it back in any descendant view.
- Inside `body`, `@Bindable var env = env` produces `$env.activeReader` bindings into the observable.

## Composing views

### Small, named views

Break large `View` types into composable pieces. Don't fear small types.

```swift
// Kios/Views/Home/StatsHeader.swift — single-purpose ~50 LOC view
struct StatsHeader: View {
    let stats: ReadingStats
    var body: some View { ... }
}
```

Rules:

- Each view does one thing.
- Pass values *in*, callbacks *out*. Avoid reaching into the environment from deeply nested views unless the value is genuinely global (theme, current user).
- Use `@ViewBuilder` to take view closures instead of `AnyView`.

### `@ViewBuilder` over `AnyView`

```swift
// ✅ good
struct EditorialList<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack { content() }
    }
}

// ❌ avoid — type-erased, defeats SwiftUI's diffing
struct Bad: View {
    let content: AnyView
}
```

### `Equatable` views for hot paths

If a view's body is expensive and renders often, conform to `Equatable` and use `EquatableView`/`.equatable()` to short-circuit redraws when inputs haven't changed.

### Avoid mutating `@State` in computed properties

```swift
// ❌ unpredictable
var body: some View {
    self.counter += 1                  // mutation in body
    return Text("\(counter)")
}

// ✅ react via .onAppear / .onChange / .task
.onAppear { counter += 1 }
```

## Navigation

iOS 17+ APIs:

- `NavigationStack` — hierarchical push/pop. Replaces `NavigationView`.
- `NavigationSplitView` — multi-column (sidebar + content + detail).
- `TabView` — top-level tabs.
- `.sheet`, `.fullScreenCover`, `.popover` — modals.

### NavigationStack with `.navigationDestination`

```swift
NavigationStack {
    List(books) { book in
        NavigationLink(value: book.id) { BookRow(book: book) }
    }
    .navigationDestination(for: UUID.self) { bookID in
        ReaderRoute(bookID: bookID)
    }
}
```

Programmatic navigation with a path binding:

```swift
@State private var path: [UUID] = []

NavigationStack(path: $path) { ... }
```

### Modal presentation from this codebase

```swift
// Kios/Views/RootView.swift
.fullScreenCover(item: $env.activeReader) { route in
    ReaderView(bookID: route.id)
}
```

`item: Binding<Identifiable?>` is the modern pattern — present when non-nil, dismiss when set to nil.

### TabView pin pattern

```swift
// Kios/Views/RootView.swift
@State private var selectedTab: Int = 0   // pinned to prevent reset

TabView(selection: $selectedTab) {
    HomeRootView().tabItem { ... }.tag(0)
    LibraryRootView().tabItem { ... }.tag(1)
    NavigationStack { SettingsView() }.tabItem { ... }.tag(2)
}
```

The `@State` for `selectedTab` prevents `TabView` from resetting when the parent re-renders during a child's first appearance.

## Layout

### Safe areas

iOS apps live inside the **safe area** — the region that excludes status bar, home indicator, Dynamic Island, and bottom edge.

```swift
.ignoresSafeArea(edges: [.top, .horizontal])
.safeAreaInset(edge: .bottom) {
    BottomBar()
}
```

This codebase has a hard-won lesson in `CLAUDE.md`:

> `ReaderView` chrome below `ReaderHost` — use `.ignoresSafeArea(edges: [.top, .horizontal])` + `.safeAreaInset(edge: .bottom) { … }`. Blanket `.ignoresSafeArea()` lets EPUB body text bleed under the bottom strip/floating bar.

### Stacks

| | Use |
|---|---|
| `VStack` / `HStack` / `ZStack` | Default layout. |
| `LazyVStack` / `LazyHStack` | Long lists — only render visible. |
| `Grid` | Aligned 2D layout (iOS 16+). |
| `LazyVGrid` / `LazyHGrid` | Many cells in a grid. |
| `Spacer()` | Push content to edges. Use `Spacer(minLength:)` to constrain. |
| `.frame(maxWidth: .infinity)` | Fill the available width. Prefer over `Spacer` when you want to align. |

### Modifier order matters

```swift
Text("x")
    .padding()
    .background(.red)        // background covers padding

Text("x")
    .background(.red)        // background only covers text
    .padding()
```

Read modifiers top-down: each wraps the previous.

## Touch targets and HIG

Apple's hard rule: interactive elements should be **at least 44×44 pt**.

```swift
// Kios/Views/Editorial/EditorialTheme.swift
static let cellMin: CGFloat = 44    // min touch target (iOS HIG)
```

Apply with `.frame(minWidth: 44, minHeight: 44)` or by making the `Button` label's intrinsic size hit 44pt.

### Spacing

- 8pt minimum between adjacent interactive elements.
- 16pt typical between sections.
- 20pt outer padding from screen edge (this codebase uses 16/20pt — see `EditorialNavBar`).

## Dynamic Type

Support text scaling from `xSmall` → `accessibility5`. Use semantic fonts:

```swift
Text("Title").font(.title)        // scales with user setting
Text("Body").font(.body)
Text("Caption").font(.caption2)
```

For custom sizes, use a scaled font:

```swift
Text("x").font(.system(size: 17).leading(.loose))
```

Or, in this codebase:

```swift
// Kios/Views/Editorial/EditorialTheme.swift
static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .serif)
}
```

Note: fixed-size fonts via `size:` do **not** scale with Dynamic Type. For body text, prefer `.font(.body)` and let the user's setting drive it. Editorial uses fixed sizes for the design system; that's a deliberate trade-off — verify with `Increase Contrast` and at the largest accessibility size before shipping.

## Dark mode

Use semantic colors:

- `.primary` / `.secondary` / `.tertiary` for text.
- `Color(.systemBackground)` / `Color(.secondarySystemBackground)` for surfaces.
- Asset catalog colors auto-adapt if you provide light + dark variants.

This codebase ships **light-only** editorial colors (`EditorialTheme.bg = 0xFAF8F4`). If/when dark support is added, mirror each token to a dark counterpart and read via `Color(light:dark:)` (iOS 17+).

## Accessibility

Every interactive element needs a label that reads correctly via VoiceOver:

```swift
Button(action: ...) {
    Image(systemName: "plus")
}
.accessibilityLabel("Add book")
.accessibilityHint("Opens the import picker")
```

System controls (`Toggle`, `Stepper`, `Text`) read their label automatically. For icon-only buttons, **always** add `.accessibilityLabel`.

```swift
// Kios/Views/Editorial/EditorialComponents.swift
struct EditorialNavIconButton: View {
    let systemName: String
    var accessibilityLabel: LocalizedStringKey   // required, not optional
    let action: () -> Void
    var body: some View {
        Button(action: action) { ... }
            .accessibilityLabel(accessibilityLabel)
    }
}
```

Other accessibility tools:

- `.accessibilityElement(children: .combine)` — merge children into one element.
- `.accessibilityHidden(true)` — hide decorative content.
- `.accessibilityAction(named:)` — add custom rotor actions.

Test with VoiceOver (`Settings → Accessibility → VoiceOver`) and the **Accessibility Inspector** in Xcode.

## Animations

```swift
Button("toggle") { withAnimation(.spring) { isOn.toggle() } }

// Or implicit:
.animation(.easeInOut, value: isOn)
```

Use `.snappy`, `.spring`, `.smooth`, `.bouncy` (iOS 17+) for system-feel animations. Avoid heavy `.linear(duration:)` unless you have a reason.

For animations driven by state changes use `.animation(_, value:)` not the deprecated `.animation(_:)`.

## Common pitfalls

- **`Image(systemName:)` size.** Use `.font(.body)` or `.imageScale(.large)` — the SF Symbol scales with its host font.
- **`List` vs `LazyVStack`.** `List` ships with row separators, swipe-to-delete, section headers; `LazyVStack` gives you raw layout control. Pick `List` for tabular data, `LazyVStack` for design-heavy scrolling.
- **Re-creating `@State`-owned objects.** `@State private var vm = ViewModel()` — the initializer runs once. Don't put expensive setup in the initializer of a view's stored `@State`.
- **Identity in `ForEach`.** Use `id: \.someStableID` or `Identifiable`. Using `\.self` on non-stable types causes redraw thrash.

## Patterns from this codebase

### Editorial design system

`Kios/Views/Editorial/` is a tokenized design system. Use it instead of reaching for raw colors/fonts:

```swift
Text("Continue reading")
    .editorialEyebrow()                       // tracked uppercase mono

Color(EditorialTheme.surfaceAlt)              // F2EFE8
EditorialTheme.serif(size: 34, weight: .bold) // serif title
```

When bundling custom fonts (Newsreader, Geist), swap inside `EditorialTheme.swift` — call sites stay untouched. See `CLAUDE.md` for the bundling plan.

### Scene phase reactions

```swift
// Kios/Views/RootView.swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active { Task { ... } }
    if newPhase == .background { env.stats.sessionDidClose(reason: .backgrounded) }
}
```

Use `scenePhase` for lifecycle hooks tied to backgrounding — that's where you flush pending writes, end sessions, save state.

### `.task` for async on appear

```swift
.task {
    await env.seedSampleBooksIfNeeded()
}
```

Prefer `.task { … }` over `.onAppear { Task { … } }`. The former auto-cancels on view disappear.

## See also

- [`swiftdata.md`](swiftdata.md) — `@Query`, `ModelContext` in views.
- [`localization.md`](localization.md) — `LocalizedStringKey` in views.
- `Kios/Views/Editorial/` — the design system.
- Apple's HIG: https://developer.apple.com/design/human-interface-guidelines/
