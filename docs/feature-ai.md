# On-device AI: chapter summaries and ask-about-selection

Living document — update when behavior changes. Companion to the spec at
`docs/superpowers/specs/2026-05-14-gemma-mlx-summaries-design.md` and the
implementation plan at `docs/superpowers/plans/2026-05-14-gemma-mlx-summaries.md`.

## What the feature does

Two things, both available from the reader, both entirely on-device:

- **Chapter summary.** Tap the `sparkles` button in the reader's top bar (or the inline "Summarise this chapter" row in the bottom bar) to get a summary of the current chapter. By default it summarizes only what the reader has read so far (no spoilers); a toggle in the sheet switches to "Full chapter". Summaries are cached per `(book, chapter, scope, engine)` and regenerable on demand.
- **Ask about selection.** Select text inside the reader, tap **Ask AI** in the system edit menu, and ask a question about the passage. Single-shot, ephemeral, no persistence.

Both are **opt-in** and **default OFF**. Nothing reaches the AI runtimes until the user enables the master toggle in Settings.

## The two engines

The reader supports two interchangeable engines behind a single `LanguageModel` protocol. The user picks one in Settings; the system substitutes the other when the preferred one is unusable.

| Engine | What it is | Where it runs | Download | Context budget | Available on |
|---|---|---|---|---|---|
| **Built-in** | Apple's Foundation Model | On-device, via the system framework | None — bundled with iOS | ~12 KB of characters (~3 K tokens) | iOS 26+ on Apple Intelligence-eligible devices |
| **Bigger context** | Google Gemma 3 4B, 4-bit quantized, via MLX | On-device, via MLX Metal kernels | ~3.4 GB one-time, from Hugging Face | ~96 KB of characters (~32 K tokens) | iOS 17+, devices with ≥ 8 GB RAM |

**Why both?** Apple's model is small and fast, but its 4 K-token context window forces map-reduce summarization on average chapters (lossy, slow, janky streaming). Gemma fits a typical chapter in one shot, preserves more nuance, and looks identical in token-rate on the iPhone 17 Pro. The cost is the 3.4 GB download and an 8 GB RAM gate.

Once a user has downloaded Gemma, the picker defaults to it. Built-in stays as a fallback for users who haven't downloaded yet or can't (RAM-limited, iOS 17–25 fine, but Apple Intelligence is iOS 26+).

## The fallback ladder

`AIAvailability.resolved(preferred:userEnabled:)` decides which engine actually runs for a given request. The rules, top to bottom:

1. **Master toggle off** → no engine, no AI UI shown at all.
2. **Preferred engine is `.available`** → use it.
3. **Preferred is unavailable, the other engine is `.available`** → use the other one transparently; the request still goes through but the sheet's footer attributes the engine that actually ran.
4. **Both unavailable** → AI entry points stay hidden in the reader; Settings still shows why each engine is unavailable.

"Unavailable" is per-engine and has named reasons (`unsupportedOS`, `unsupportedDevice`, `modelNotReady`, `modelNotDownloaded`, `modelDownloading`, `modelCorrupt`). The Settings picker grays out each segment with a footnote explaining why the user's device can or can't use it.

This means: a user with a fresh install on an iPhone 17 Pro with iOS 26 sees the picker default to "Bigger context (recommended)" with a download cell beneath. Tapping the sparkles button in the reader works *immediately* via Built-in fallback. As soon as Gemma finishes downloading, the same button switches to Gemma.

## Where the model files live

Gemma weights, when downloaded, live in:

```
<Application Support>/kios/ai-models/gemma-3-4b-it-q4-mlx/
├── config.json
├── tokenizer.json
├── tokenizer_config.json
├── model.safetensors
└── …
```

`Application Support`, not `Caches`: iOS doesn't purge it. Each file is flagged `isExcludedFromBackup` at install time, so the 3.4 GB doesn't count against the user's iCloud storage.

The catalog (`Kios/Services/AI/ModelCatalog.swift`) pins:
- A specific Hugging Face commit SHA (`mlx-community/gemma-3-4b-it-4bit`)
- Per-file SHA-256 hashes
- Per-file sizes

Pinning + per-file SHA verification is non-negotiable. Hugging Face's `main` branch can change; without the pin we could silently load anything. SHAs are computed once at plan time and frozen in source.

## Settings UX

The AI section in Settings has one master toggle and, when enabled, an engine picker with a per-engine download/install cell.

```
┌─ AI assistant ────────────────────────────────────┐
│  Enable AI features                  [○━━]        │  master toggle, default OFF
│                                                   │
│  (when ON:)                                       │
│  ─────────────────────────────────────────────    │
│  ┌─────────────────┬──────────────────────────┐   │
│  │ Bigger context  │ Built-in                  │   │  per-engine grey-out
│  │ (recommended)   │ (Apple Intelligence)      │   │   when unavailable
│  └─────────────────┴──────────────────────────┘   │
│  Bigger context requires 8 GB of RAM. [footnote]  │
│                                                   │
│  📥 Download model (~3.4 GB)                      │  shown when Gemma is preferred
│  [ Download ]                                     │   and not installed
│                                                   │
│  Allow cellular download         [○━━]            │
└────────────────────────────────────────────────────┘

┌─ Cache ────────────────────────────────────────────┐
│  Clear cached summaries (▶)                       │
└────────────────────────────────────────────────────┘
```

Notable UX details:

- The picker shows **both** engine segments at all times when AI is on, even when one isn't usable. The unavailable segment greys out with a footnote ("Requires 8 GB of RAM", "Requires iOS 26"). This is intentional — hiding the segment leaves the user wondering why the option they heard about isn't here.
- Toggling master off keeps the cached summaries on disk. Wiping requires the explicit **Clear cached summaries** action.
- Cellular download is off by default. The toggle is only relevant when "Bigger context" is the preferred engine.
- The **first-enable explainer sheet** appears once per install on the first toggle-ON. Gated by `aiSettings.didShowFirstEnableSheet`.

## Reader entry points

When AI is enabled *and* `AIAvailability.resolved(...)` returns a non-nil engine:

- The **top bar** shows a `sparkles` button left of "Contents". Tap → `ChapterSummarySheet`.
- The **bottom bar** shows a prominent "Summarise this chapter" row with the resolved engine name in the eyebrow. Tap → `ChapterSummarySheet` (same sheet).
- The system **edit menu** (long-press on selected text) gains an **Ask AI** entry. Tap → `AskAboutSelectionSheet` with the selection pre-filled.

When AI is disabled, or no engine is usable, **none of these surfaces render**. There is zero AI UI visible to a user who hasn't opted in.

## What's cached, what isn't

| Surface | Cached? |
|---|---|
| Chapter summaries | Yes — SwiftData `ChapterSummary` rows keyed by `(book, chapter, scope, engine)`. Invalidated by source-text SHA. |
| Ask-about-selection answers | No — ephemeral per sheet. |
| AI settings (master toggle, preferred engine, etc.) | Yes — `UserDefaults` via `AISettings`. |
| Gemma model weights | Yes — `Application Support/kios/ai-models/`. |

Composite cache ID:

```
"<book.id>|<chapter.href>|<scope>|<engine>"
```

The `engine` segment means switching engines never collides with a prior cache row. The same chapter at the same scope can have separate `Built-in` and `Gemma` summaries, both valid. **Clear cached summaries** wipes both.

## Code organization

Boundary mirrors the existing `Core` ⇄ `Kios` split:

```
Core/Sources/Core/AI/
├── LanguageModel.swift        # protocol + SummaryScope
├── PromptTemplates.swift      # system+user prompt builders
├── TextChunker.swift          # paragraph/sentence-aware splitting
├── MapReduceSummarizer.swift  # multi-chunk summary with progress
└── Testing/MockLanguageModel.swift   # public test helper

Kios/Services/AI/
├── AIEngine.swift                       # enum, in Kios so it can reference UI strings
├── DeviceCapability.swift               # physicalMemory + 7.5 GB Gemma threshold
├── AIAvailability.swift                 # per-engine availability + fallback ladder
├── AISettings.swift                     # UserDefaults-backed @Observable
├── ModelAsset.swift                     # asset descriptor (id, repo, revision, files)
├── ModelCatalog.swift                   # frozen catalog of pinned assets
├── ModelAssetStore.swift                # disk truth + SHA-256 integrity
├── ModelDownloadService.swift           # URLSession background download
├── ModelRuntime.swift                   # actor: load/idle/evict + MLX runner
├── GemmaChatTemplate.swift              # pure prompt formatter
├── FoundationModelsLanguageModel.swift  # adapter — iOS 26+ FM (+ FoundationModelsError translation)
├── MLXGemmaLanguageModel.swift          # adapter — MLX Gemma
├── AILanguageModelProvider.swift        # concrete provider routing FM or MLX
├── PublicationChapterTextExtractor.swift # adapter — Publication+href → plain text
├── ChapterTextExtractor.swift           # Readium → plain text with cutoff
└── AISummaryService.swift               # @MainActor @Observable orchestrator

Kios/Models/
├── ChapterSummary.swift                 # @Model, Foundation-only (KiosControls-safe)
└── (ChapterSummary+ID.swift)            # NB: id-builder lives in Services/AI/

Kios/Views/Reader/
├── ChapterSummarySheet.swift
├── AskAboutSelectionSheet.swift
├── ReaderChrome.swift                   # sparkles button + bottom-bar AI row
├── ReaderContainerVC.swift              # Ask AI editing action
├── ReaderHost.swift                     # canAskAI plumbing
└── ReaderView.swift                     # resolvedAIEngine + sheet presentations

Kios/Views/Settings/
├── AIEnginePicker.swift                 # segmented control + per-segment grey-out
├── ModelDownloadCell.swift              # download/cancel/delete/progress states
└── AIFirstEnableSheet.swift             # one-time explainer
```

The `LanguageModel` protocol lives in `Core/` because it must stay pure-Foundation: neither `FoundationModels` nor `MLXLLM` is imported in `Core/`. `Kios/` provides the two adapters and the orchestrator.

`FoundationModelsLanguageModel.swift` also hosts a `FoundationModelsError: LocalizedError` translation type. Apple's `LanguageModelSession.GenerationError` cases (`assetsUnavailable`, `exceededContextWindowSize`, `guardrailViolation`, `rateLimited`, `concurrentRequests`, `unsupportedLanguageOrLocale`, `unsupportedGuide`, `decodingFailure`, `refusal`) all surface as a generic `error -1` via `localizedDescription`. The adapter catches them and maps each to an actionable user-facing message (e.g., `assetsUnavailable` → "open Settings → Apple Intelligence & Siri and let it finish downloading"). Anything we throw from the FM path is wrapped in `FoundationModelsError`, so the summary sheet's error card always says something useful.

## How a summary actually flows

```
User taps sparkles
  → ReaderView.presentSummarySheet()
    → resolvedAIEngine = AIAvailability.resolve(…).resolved(…)
    → ChapterSummarySheet appears with engine + cutoff in its context
  → Sheet's .task(id: scope) fires
    → AISummaryService.summarizeCurrentChapter(…, engine:)
      → PublicationChapterTextExtractor.extract(bookID:chapterHref:cutoff:)
          (resolves href to Link, reads HTML, strips tags, aligns cutoff to paragraph)
      → SHA-256 over the extracted body → sourceHash
      → ChapterSummary cache lookup by composite id
          hit + hash match → state = .done(cached.text); STOP
          else → continue
      → AILanguageModelProvider.languageModel(for: engine)
          .foundationModels → FoundationModelsLanguageModel()
          .gemma3_4b        → ModelRuntime.shared.acquire(at: directory) → MLXGemmaLanguageModel
      → if body.count ≤ contextBudgetCharacters: single-shot
        else: MapReduceSummarizer (chunk → partial → reduce)
      → stream tokens → state = .streaming(accumulated)
      → on finish: upsert ChapterSummary, state = .done
```

## ModelRuntime lifecycle

The Gemma runtime is heavy (a 3.4 GB MLX module + KV cache in Metal memory). To stay a good citizen on a memory-pressured device, `ModelRuntime` is an `actor` that:

| Event | What happens |
|---|---|
| First `acquire(at:)` | Calls `RunnerLoading.load(from:)` — the MLX implementation loads weights into Metal |
| Subsequent `acquire(at:)` with same directory | Reuses the loaded runner; updates `lastUsed` |
| `release()` | Drops the runner immediately |
| `evictIfIdle()` | Drops the runner if `lastUsed` is older than the idle timeout (default 5 min) |

Manual hookup points (not yet wired into app lifecycle — TODO if this matters):
- App backgrounded ≥ 30 s → call `release()`
- `UIApplication.didReceiveMemoryWarningNotification` → call `release()` immediately

The Built-in engine doesn't go through `ModelRuntime` — `LanguageModelSession` is cheap to construct, one per request.

## Framework gotchas (load-bearing patterns)

The bugs we hit while wiring this feature up landed permanent decisions in the code. Each one is short and easy to "simplify" by accident — these are the ones to leave alone.

### `AISettings` must use stored properties with `didSet`, not computed UserDefaults accessors

`@Observable` only emits change notifications for *stored* property mutations. An earlier version of `AISettings` used computed properties that read/wrote `UserDefaults`:

```swift
// WRONG — toggling featuresEnabled writes to UserDefaults but
// SwiftUI never re-renders, so the engine picker stays hidden.
var featuresEnabled: Bool {
    get { defaults.bool(forKey: Keys.featuresEnabled) }
    set { defaults.set(newValue, forKey: Keys.featuresEnabled) }
}
```

Correct pattern (current code):

```swift
@ObservationIgnored private let defaults: UserDefaults

var featuresEnabled: Bool {
    didSet { defaults.set(featuresEnabled, forKey: Keys.featuresEnabled) }
}

init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.featuresEnabled = defaults.bool(forKey: Keys.featuresEnabled)
    // ...other keys hydrated the same way
}
```

If you add a new setting, follow this shape. If `defaults` itself is observed by mistake (no `@ObservationIgnored`), that's also a bug — it's not part of the public state.

### `ModelDownloadService` must use `URLSessionDownloadDelegate`, not `download(from:)`

`URLSessionConfiguration.background(withIdentifier:)` does not support the async convenience methods. Calling `await session.download(from: url)` on a background session throws an `NSException` with the message *"Completion handler blocks are not supported in background sessions"* and aborts the process. Symptom: the user taps Download and the app instantly crashes with an `EXC_CRASH (SIGABRT)` deep inside `__NSURLBackgroundSession`.

The current implementation uses a delegate-driven path that works for any session config (background, default, or ephemeral): per-file `session.downloadTask(with: url).resume()`, with a per-file `CheckedContinuation<URL, Error>` that the delegate methods resume. The delegate also moves the temp file to a stable path *before* bouncing back to MainActor — `URLSession` deletes its temp file the moment `didFinishDownloadingTo` returns.

If you ever switch back to `await session.download(from:)`, you must also drop the background config — and you'll lose download-survives-app-suspension. Don't.

### MLX cannot run on the iOS Simulator

`mlx-swift-examples`'s Metal kernels require Apple Silicon GPU features that the iOS Simulator's Metal subset doesn't provide. Loading a model crashes the process inside `mlx::core::metal::Device::Device()` constructor.

`AILanguageModelProvider` short-circuits this with a compile-time guard:

```swift
case .gemma3_4b:
    #if targetEnvironment(simulator)
    throw ProviderError.gemmaUnsupportedOnSimulator
    #else
    // ...real load path...
    #endif
```

Result: on the simulator, tapping Summarize with Gemma selected shows an error card explaining the limitation and pointing the user at the Built-in engine. Settings still allows the full download/install/delete flow on simulator (so that path can be tested), just not inference. Real-device path is unchanged.

### Don't clear `summaryService` in `ReaderView.onDisappear`

SwiftUI fires `.onDisappear` on the parent view when a `.sheet(item:)` covers it. An earlier version of `ReaderView` had:

```swift
// WRONG — clears the service at the exact moment the sheet wants to read it.
.onDisappear { summaryService = nil }
```

This made the sheet render completely blank. The cleanup wasn't necessary anyway — `ReaderView` is recreated on each `fullScreenCover` presentation, so its `@State` is fresh per book open.

### Bundle the service into the sheet's context, not a separate `@State`

Even after removing the `onDisappear` clearing, the sheet still rendered blank in some races. Setting `summaryService` and `summarySheet` synchronously *did not* guarantee the sheet's content closure observed them together — `.sheet(item:)` evaluated its closure with stale sibling state.

Fix: the service is bundled into `SummarySheetContext` / `AskSheetContext`:

```swift
struct SummarySheetContext: Identifiable {
    let id = UUID()
    let bookID: UUID
    let chapterHref: String
    // ...
    let service: AISummaryService   // ← bundled here, not read from sibling @State
}
```

The sheet content closure now reads `context.service`, so there's no inter-state synchronization to get wrong. Don't refactor this back to a separate `@State` "for cleanliness" — the bundling is what makes the sheet render reliably.

### `ChapterSummarySheet` uses `hasStartedFirstRun` to avoid a blank moment

When the sheet first appears, `service.summaryState` is `.idle` and `.streaming(...)` hasn't fired yet — but the `.task(id: scope)` is already running. Without a flag, the body renders the placeholder *"Tap Summarize to begin."* even though summarization is in flight. Looks broken.

The sheet keeps a local `@State private var hasStartedFirstRun: Bool` that flips to `true` inside `runSummary()` before awaiting. The body then shows a `Preparing summary…` `ProgressView` for the `.idle` and `.streaming("")` cases once a run is in flight. The `.idle` placeholder copy only shows on the very first appear, before the task fires. Removing this flag will make the sheet look broken during model load (especially noticeable on Gemma's ~1 s initial weight load).

## Testing

Core tests use the Swift Testing framework, run via `cd Core && swift test --no-parallel` (or `make test-core`). iOS tests run via `xcodebuild test` against the `iPhone 17 Pro` simulator (or `make test-ios`).

| Layer | Runner | Notes |
|---|---|---|
| `LanguageModel`, `SummaryScope`, `PromptTemplates`, `TextChunker`, `MapReduceSummarizer` | `swift test` | Pure value/logic — uses `MockLanguageModel` |
| `AIEngine`, `ModelAsset`, `ModelCatalog`, `DeviceCapability` | `xcodebuild test` | Pure value types — encode/decode, threshold |
| `AISettings` | `xcodebuild test` | UserDefaults suite-based isolation |
| `AIAvailability` | `xcodebuild test` | Exhaustive matrix via stubs |
| `ModelAssetStore` | `xcodebuild test` | Real `FileManager` against temp `URL`s |
| `ModelDownloadService` | `xcodebuild test` | Mock `URLProtocol`; ephemeral session config |
| `ModelRuntime` | `xcodebuild test` | Injected `RunnerLoading` stub (no real MLX) |
| `GemmaChatTemplate` | `xcodebuild test` | Pure formatter |
| `ChapterTextExtractor` | `xcodebuild test` | Fixture EPUB at `KiosTests/Fixtures/sample-chapter.epub` |
| `AISummaryService` | `xcodebuild test` | Mock provider + stub extractor |
| `ChapterSummary` @Model | `xcodebuild test` | In-memory `ModelContainer` |
| `FoundationModelsLanguageModel`, `MLXGemmaLanguageModel` | Manual smoke only | Thin adapters; real model calls aren't unit-testable in CI |

### MockLanguageModel

Lives at `Core/Sources/Core/AI/Testing/MockLanguageModel.swift` (yes, in `Sources/` — it's a public test helper, accessible to both Core's own tests and Kios's test target). Per-instance state, no shared statics.

Three response shapes:
- `.streamChunks([String], delayPerChunk: Duration)` — happy path
- `.fail(any Error)` — error path
- `.stallForever` — cancellation path

### Strict-concurrency footgun

Several tests capture state in `@Sendable` closures (progress callbacks, mock provider mutations, download integrity flags). Swift 6 strict concurrency rejects `var X; closure { X = … }`. The established pattern in this project is a small NSLock-protected class:

```swift
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (Int, Int) = (0, 0)
    var value: (Int, Int) { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ done: Int, _ total: Int) { lock.lock(); _value = (done, total); lock.unlock() }
}
```

See `Core/Tests/CoreTests/AI/MapReduceSummarizerTests.swift` and `KiosTests/Services/AI/ModelDownloadServiceTests.swift` for examples.

## Manual smoke test (PR checklist)

Each PR that touches AI code should pass these checks. Stage the device/simulator combinations you can:

- **iPhone 17 Pro (16 GB), iOS 26+:**
  - [ ] Enable AI toggle. First-enable sheet appears.
  - [ ] Picker defaults to "Bigger context"; download cell visible.
  - [ ] Tap Download — Wi-Fi-only by default, progress visible, ~3 min on Wi-Fi.
  - [ ] After install, picker shows installed state.
  - [ ] Summarize a short chapter. Single-shot streams smoothly. Footer reads "Gemma 3 4B".
  - [ ] Switch picker to "Built-in". Summarize same chapter — separate cache row, footer reads "Apple Intelligence".
- **iPhone 15 (base, 6 GB) or older, iOS 26+:**
  - [ ] Picker greys "Bigger context" with "Requires 8 GB RAM" footnote.
  - [ ] FM works; map-reduce on long chapters.
- **iPhone 12 (4 GB), iOS 17–18:**
  - [ ] Master toggle disabled with explanation row. Reader has no AI UI.
- **Storage edge cases:**
  - [ ] Fill device to < 4 GB free, attempt download. `notEnoughStorage` error shown.
  - [ ] Cancel mid-download. Disk reports partial. Re-tap Download → resumes (URLSession background session).
  - [ ] Lose Wi-Fi mid-download with cellular off. Pauses cleanly. Resumes on Wi-Fi return.
- **Memory hygiene:**
  - [ ] Summarize with Gemma, background the app for 1 min, foreground, summarize again. First call has model-reload latency (~1 s); subsequent calls warm.
- **Delete:**
  - [ ] Hit Delete model. Confirm. Weights gone. Picker reflects new state.
- **Cache survives switch:**
  - [ ] Summarize with Gemma, switch to FM, summarize again. Both rows in cache.
  - [ ] Master toggle OFF then ON. Cache rows survive.
- **Master toggle off:**
  - [ ] **Every AI surface disappears**: sparkles in top bar, "Summarise" row in bottom bar, "Ask AI" in edit menu. None of them appear. **This is load-bearing for the opt-in privacy story.**

## Gotchas and debugging

### "The picker shows 'Bigger context' but the model never downloads"

Check `aiSettings.allowCellularDownload`. If off and you're on cellular, the URLSession background task waits silently. Toggle the cellular setting, or get on Wi-Fi.

### "Summaries take forever on Built-in"

Map-reduce. Apple FM's 4 K-token context window forces multi-step summarization on chapters over ~2,500 words. This is expected; switch to Gemma or read shorter chapters. Don't try to "fix" by raising `contextBudgetCharacters` — that'll just produce truncation errors from the runtime.

### "MLX model crashed the app"

Check Console for `jetsam` log entries. iOS killed the process for memory pressure. Apple's Foundation Model is more conservative; if you're hitting jetsam on Gemma, dial down concurrent work (close other apps), or fall back to Built-in for that session.

### "I keep seeing 'Re-download required'"

`InstallationStatus.corrupt` — a file SHA didn't match the pinned catalog hash. This is intentional. Cause: either the asset directory was tampered with manually, or the upstream Hugging Face repo changed (shouldn't happen — we pin a revision SHA). Tap **Delete model** and **Download** again.

### "I want to test on simulator but FM isn't available"

Apple Intelligence on the simulator is inconsistent — most simulators report `assetsUnavailable` even after toggling AI on in iOS Settings. The summary sheet will say *"Apple Intelligence assets aren't ready on this device."* (translated by `FoundationModelsError`). Don't rely on it. Use a physical iOS 26 device with Apple Intelligence enabled.

### "I want to test Gemma on simulator"

You can't run Gemma inference on the simulator at all — MLX requires real Apple Silicon Metal kernels. The provider returns `gemmaUnsupportedOnSimulator`; the sheet shows a clear error. The download/install/delete flow does work on simulator, so you can exercise the asset pipeline there. For inference, you need a physical iPhone 15 Pro / 16 / 17 with iOS 17+ and ≥ 8 GB RAM.

### "I want to verify gating without touching the simulator"

```
git grep "resolvedAIEngine\|canSummarize\|canAskAI\|featuresEnabled" Kios/Views/
```

Every AI entry point should pass through `AIAvailability.resolve(...).resolved(preferred:userEnabled:)` somewhere upstream. If you find a button or row that doesn't, it's a gating bug — file it.

## Privacy notes

The reader does not send any text to a server when AI features are used. There are two paths and both are local:

- **Built-in:** Apple's on-device Foundation Model. No network. Apple offers a "Private Cloud Compute" path for its own features, but third-party apps (us) only get the on-device runtime.
- **Bigger context:** Gemma weights are downloaded once from Hugging Face's public CDN. After that, inference is local Metal compute. No telemetry, no upload of prompts or outputs.

The master toggle defaults to OFF, and **no AI framework symbol is touched at runtime until the user enables it**. This is verifiable: `AILanguageModelProvider.languageModel(for:)` is the only code path that constructs a real `FoundationModelsLanguageModel` or `MLXGemmaLanguageModel`, and it isn't called from any view body unless `aiSettings.featuresEnabled == true`. Set a breakpoint there if you want to confirm.

## What's deliberately not built

- **Whole-book summarization** — even Gemma's 32 K-token context can't fit a 300-page novel (~80–100 K words). Revisit when there's a credible local model with >100 K-token usable context.
- **Cross-device sync of summaries** — neither kosync nor Kobo carries arbitrary blobs.
- **Cloud model fallback** — local-only by design.
- **Multi-turn chat for selection Q&A** — single-shot is enough for "what does this paragraph mean?"
- **Multimodal Gemma** — Gemma 3 4B can take images; we don't.
- **Lower-tier Gemma weights** — we don't ship Gemma 3 1B for < 8 GB devices. They get Built-in (if eligible) or no AI.
