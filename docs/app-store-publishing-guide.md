# App Store Publishing Guide

> Reference document covering everything required to take this app from "builds locally" to "live on the App Store." Each phase is independent and can be executed on its own schedule; the order roughly matches the dependency graph (Phase 0 decisions feed Phase 3 setup, etc.).

## Context

This iOS app — codenamed `ios-reader` in the repo, product name **Kios** — is a native SwiftUI + SwiftData EPUB reader (iOS 17+, iPhone + iPad) that talks to self-hosted servers over OPDS (catalogue), KOSync, and the Kobo sync protocol. As of **2026-05-18**, build 1.0(21) is **submitted to Apple Beta App Review** for the *Public Beta* external TestFlight group; once approved (~24h), external testers become invitable. Remaining work for full App Store launch: real app icon, screenshots, marketing copy, ATS decision.

This document captures the full set of requirements, decisions, and process steps so future submission work has a single reference.

## Key decisions captured so far

- **App name**: **Kios**. App Store listing name: **Kios Reader** (the "Reader" descriptor differentiates Class 9 goods from the existing *Kios, Inc.* mark and adds modest ASO weight). Home-screen `CFBundleDisplayName` stays as **Kios**. Treated as a coined word — no public reference to the Kobo+iOS etymology in marketing, store copy, or readme. Project is free + open source + niche, so the residual risks (kiosk search-collision, low-probability C&D from Kios, Inc.) are recoverable rather than existential. See "Phase 0a — Picking a name" for the analysis trail (including the rejected *Aldus* alternative).
- **Bundle ID**: `com.raphi011.kios`. Locked. Matches the GitHub-handle namespace; short and ages well. Replaces the working-title `me.iosreader.iOSReader`.
- **Apple Developer enrollment**: deferred until the app is "ready to launch."
- **Reviewer access strategy**: add local EPUB file import so the app is fully testable offline; reviewer notes emphasize the two bundled sample books (Frankenstein, Moby-Dick) — sync features are optional and not required to evaluate the app. No demo server credentials needed.
- **Positioning is server-agnostic**: never name a specific server implementation in user-facing copy. Sync protocols (OPDS, KOSync, Kobo) are open specs and the app works with any compliant server. This avoids App Store 4.2 "wrapper" framing risk and is factually accurate.
- **Visual assets**: still need designed mark + screenshots. A **placeholder icon from [IconikAI](https://www.iconikai.com/) is wired into the build** (`Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`) so the simulator install + Xcode validation pipelines work end-to-end today. The placeholder **must be replaced with a real designed mark before public launch** — see "1.6 App icon assets" for the AI tooling shortlist evaluated during the placeholder pass.
- **Submission path**: TestFlight beta first, then promote to App Store review.

## Current state (verified via codebase exploration)

TestFlight internal builds have been live since 2026-05-14. Build 1.0(21) was submitted for external Beta App Review on 2026-05-18.

| Area | Status |
|---|---|
| Bundle ID | ✅ `com.raphi011.kios` (`project.yml:40`) |
| Deployment target | ✅ iOS 17+, iPhone + iPad |
| Code signing | ✅ `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = KVS38S75S8` (`project.yml:14`) |
| Versioning | ✅ `CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1` (`Kios/Info.plist:17-20`). Bump `CFBundleVersion` for every TestFlight upload. |
| App icon | ⚠️ **Placeholder only** — IconikAI 1024×1024 master at `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. Replace with a real designed mark before public launch. |
| Launch screen | Auto-generated (`UILaunchScreen` empty dict in Info.plist). Skippable for v1. |
| Privacy descriptions in Info.plist | n/a — app uses no camera/photos/location/tracking |
| `PrivacyInfo.xcprivacy` | ✅ `Kios/Resources/PrivacyInfo.xcprivacy` — declares `UserDefaults` (CA92.1) + `FileTimestamp` (C617.1) Required-Reason APIs; tracking false; no data collected |
| `ITSAppUsesNonExemptEncryption` | ✅ `false` in `Kios/Info.plist:21-22` |
| `NSAppTransportSecurity` | ❌ Not configured. README still hedges (HTTPS strongly recommended, HTTP requires ATS exception). Decide before submission — see Phase 1.5. |
| EPUB document handler | ✅ `CFBundleDocumentTypes` for `org.idpf.epub-container` + `public.epub` (`Kios/Info.plist:52-67`) |
| Local EPUB import | ✅ `LocalImportService.swift` + `.fileImporter` in `LibraryRootView` and `SettingsView`; two sample books bundled (`frankenstein.epub`, `moby-dick.epub`) for offline reviewer testing |
| Capabilities/entitlements | None declared (no iCloud, push, IAP, App Groups, Sign in with Apple) |
| Third-party SDKs | Readium (swift-toolkit 3.9+), ZIPFoundation; **no analytics, no ad SDKs, no trackers** |
| CI/CD | Makefile only; no fastlane, no GitHub Actions, no `ExportOptions.plist`. TestFlight uploads currently manual via Xcode Organizer. |
| App Store Connect metadata | ✅ App Information (Primary Books / Secondary Productivity, Content Rights No, Age Rating 4+), Pricing $0.00 worldwide, App Privacy "Data Not Collected" published, TestFlight Test Information filled. **Marketing copy + screenshots still pending** for full App Store submission (not required for TestFlight). |
| Privacy policy + beta test info | ✅ `PRIVACY.md` hosted at https://raphi011.github.io/kios/PRIVACY via GitHub Pages (live since 2026-05-17). `BETA.md` content pasted into ASC TestFlight Test Information + per-build "What to Test". Both files scrubbed of any specific server-implementation references — strictly server-agnostic framing. |
| External TestFlight | 🟡 Build 1.0(21) **submitted to Beta App Review 2026-05-18** (~24h Apple turnaround). `Public Beta` external group created. After approval, invite testers via public link or email. |

---

## Phase 0a — Picking a name — ✅ DONE (name: **Kios**)

> Decision-trail preserved below for posterity. The "current recommendation" subsection still pitches *Aldus* and is now historical context only — Kios was chosen instead. See the doc preamble for the rationale.

The original working title `iOSReader` was generic, low-distinctiveness in App Store search, and ineligible for trademark protection. Apple also rejects names that are descriptive-only (Guideline 4.1 "Copycats" treats generic device-prefixed names as low-quality). A real name is needed **before** Phase 0b, because the choice cascades into bundle ID, App Store Connect record, domain, privacy policy URL, marketing copy, and icon design.

### Naming criteria

Score candidates against these dimensions before committing:

1. **Distinctive** — passes a Google search without drowning in noise. The first page of results should be empty or unrelated. If page 1 has another mobile app, score it down.
2. **App Store-clear** — search the iOS App Store; if another app has the exact name or near-miss, Apple may reject yours. *App Store names must be globally unique per platform.*
3. **Trademark-clear** — quick check at [tmsearch.uspto.gov](https://tmsearch.uspto.gov) (US) and [euipo.europa.eu](https://www.tmdn.org/tmview/) (EU). Apps fall under Class 9 (software) and Class 42 (SaaS). You don't need to file a trademark to ship, but you do need to not infringe an existing one.
4. **Domain available** — `.app` (Google-run, requires HTTPS, perfect for app marketing pages) or `.com` is ideal. Check at [domains.google](https://domains.google) or [namecheap.com](https://namecheap.com). A domain isn't required, but you'll want one for the privacy policy / support URLs.
5. **Speakable & spellable** — say it on a podcast; type it from memory; would a non-English speaker get it close? Aim for ≤3 syllables.
6. **Pronounceable across locales** — avoid clusters that don't exist in major target languages.
7. **Not device-prefixed** — Apple discourages names containing "iOS", "iPhone", "iPad", "Apple", or "Mac" unless you're Apple. Drops `iOSReader` out automatically.
8. **Icon-able** — does the name suggest a visual mark? Single-letter logos work well for short names (M for Marvin, Y for Yomu).

### Direction options

The app sits in a niche: *"my own self-hosted library, beautifully read on iOS, syncing across devices."* Five name directions, each with examples. None of these are verified for App Store/trademark clearance — that's your due diligence — but they're starting points.

#### A. Bookbinding / book-physical-object vocabulary
Evocative without being generic. Often available because the words are old and obscure.

- **Folio** — a single leaf of a book (also a paper size). Elegant, single-word, common in publishing without being claimed by a major app. *Risk: Adobe has a product called Adobe Folio (defunct); some indie web apps. Search needed.*
- **Quire** — a set of pages bound together; also a verb meaning "to fold and bind." Five letters, distinctive, rarely used. Strong icon potential ("Q").
- **Codex** — a bound manuscript. Slightly overused (many crypto/dev tools); App Store check critical.
- **Vellum** — already taken by a Mac publishing app from 180g.io. Skip.
- **Marginalia** — notes in book margins. Long but evocative; "M" icon.
- **Spine** — the bound edge of a book. Double meaning: spine of a book, backbone of sync. Memorable. *Risk: "Spine" is a 2D animation tool from Esoteric Software; conflict in Class 9.*
- **Boards** — the front/back covers of a hardcover. Short, distinct.

#### B. Latin / literary roots
Slightly elevated tone, fits a "for serious readers" positioning.

- **Liber** — Latin for "book." Two syllables, short. *Risk: a few apps named Liber exist.*
- **Lectern** — a reading stand. Distinct, "L" icon.
- **Scriptorium** — medieval book-copying room. Long but evocative.
- **Recto** / **Verso** — front and back of a page. Striking, niche.
- **Glossa** — a marginal note; gloss. Short, available-sounding.
- **Atheneum** / **Athenaeum** — a literary club or library. Long, but high status.

#### C. Personal-library / self-hosted vibe
Lean into the "this is *your* library, not Amazon's" framing.

- **Shelf** — too generic; many apps.
- **Stacks** — library stacks (the back-room shelving). Friendly, plural-as-name.
- **Hoard** — your book hoard. Slightly humorous.
- **Cairn** — a personal landmark. Vague but distinctive.
- **Hearth** — your books, at home. Warm.
- **Atlas** — your map of books. Already overused.

#### D. Reading-experience verbs / made-up
Short coined words. Highest distinctiveness, but you have to teach the meaning.

- **Yomu** — Japanese for "to read." Already a paid iOS reader app — taken. Skip.
- **Lectio** — Latin for "reading." Short, distinct.
- **Pero** — meaningless but short.
- **Skim** — too generic and verb-only.
- **Voracious** — already taken by a podcast app.

#### E. Compound / portmanteau
Mash two relevant words together.

- **Bookery** — bookish + nookery. Made up but evocative.
- **Pageturn** — a turn of phrase. Available?
- **Readhome** — your reading home. Self-explanatory.
- **Folioself** — too clever.

### Research findings (verified)

Five candidates have been checked against the iOS App Store (iTunes Search API), `.com` / `.app` domain registries (whois + DNS), and Google. Results:

| Name | App Store | Domain `.com` | Domain `.app` | Verdict |
|---|---|---|---|---|
| **Folio** | **9 apps** using Folio as primary brand, including *Folio: Book & Reading Tracker* (Books) and *Folio – Save now. Read later.* (read-later) — direct adjacency to a reader. | Registered 1993, GoDaddy (premium). | Registered (yay.com NS). | **Burned.** Saturated Class 9 use; too many senior users. |
| **Quire** | *Quire* by Potix Corporation — standalone exact-match app, 10+ years of continuous use in Class 9 (task management). | Registered 1999, owned by Potix. | Registered via Cloudflare (Potix). | **Burned.** Single dominant rights-holder = easy trademark enforcement. |
| **Verso** | 3 standalone Verso apps in non-reader categories. **Verso Books** (major UK publisher since 1970) is the real conflict. | Registered 1996, Belgian registrar. | Registered (Cloudflare). | **Burned.** Real-publisher conflict in the book space. |
| **Lectio** | 3 *Lectio* apps, all religious (Lectio Divina contemplative practice). | Parked. | **Available.** | **Burned for general use.** Heavy religious connotation. |
| **Aldus** | Only *Aldus Video KYC* (unrelated category). | Registered 2000, parked at fabulous.com (likely for sale). | Registered at NameCheap (unknown owner). | **Promising.** Best candidate found. Adobe-Aldus legacy trademark needs counsel review. |

### Current recommendation

If you want to keep iterating: **Aldus** is the strongest candidate so far. Narrative fit is exceptional — Aldus Manutius (Aldine Press, Venice, 1501) literally invented the pocket-sized portable book and the italic typeface. A self-hosted EPUB reader honoring the inventor of portable reading is a clean story. Caveats:
- Adobe acquired Aldus Corporation (PageMaker, Freehand) in 1994 and may hold residual Aldus trademarks. Run a USPTO TESS search and consult a trademark attorney before committing.
- Domain acquisition will cost; `aldus.com` is parked-for-sale ($X,000+ likely). Alternatives: `aldusapp.com`, `getaldus.com`, `aldus.io`, or use the brand-name-direct-purchase pattern.

If you'd rather a clean slate: try a **second shortlist** of less-known printing/binding terms (*Aldine*, *Quarto*, *Octavo*, *Galley*, *Colophon*, *Incipit*) or coined names. These haven't been verified yet — same checks apply.

### Verification checklist for the chosen name

Before locking it in:

- [ ] Search the iOS App Store for the exact name — no existing app with that name or a confusingly similar one.
- [ ] Search USPTO TESS (US) and EUIPO TMview (EU) for the name in Class 9 (software) and Class 42 (SaaS).
- [ ] Search Google for `"<name>" app` — first page should not surface a competing mobile app.
- [ ] Check domain availability for `<name>.app` and `<name>.com`. Buy at least one before you announce.
- [ ] Check `@<name>` handle availability on Mastodon/Bluesky/X if marketing reach matters.
- [ ] Say the name out loud to three people who haven't seen the app. Do they spell it back correctly? Remember it 24 hours later?

### Bundle ID implication

Once the name is chosen, the **bundle ID** should change before first App Store upload (after upload it's permanent). Suggested format: `<your-domain-reversed>.<appname>`. Example assuming you own `raphaelgruber.com`:
- Name `Aldus` → bundle ID `com.raphaelgruber.aldus`

If you'd rather scope under a product domain (e.g. you buy `aldus.app`), then `app.aldus.ios` is also fine. The `me.iosreader.*` namespace currently in `project.yml` should be retired with the working-title name.

---

## Phase 0b — Other decisions & content (no Apple account needed)

Things you can pin down today; they all become inputs to App Store Connect later.

- [x] **Confirm bundle ID** — locked to `com.raphi011.kios`.
- [x] **App display name** — home screen `CFBundleDisplayName` = `Kios`; App Store listing name = `Kios Reader`.
- [ ] **Subtitle** (up to 30 chars) — appears under the name in the App Store listing. Examples to consider: `Self-hosted EPUB reader`, `Your library, beautifully read`. Avoid naming any specific server product.
- [x] **Primary + secondary category** (set 2026-05-17): Primary *Books*, Secondary *Productivity*.
- [x] **Pricing model** (set 2026-05-17): Free ($0.00), worldwide (175 regions).
- [x] **Age rating** (set 2026-05-17): 4+ (173 countries, AL in Brazil, ALL in Korea). 20-question questionnaire answered NO/NONE across all categories.
- [ ] **Marketing copy**: short description (170 chars), full description (4000 chars), keywords (100 chars), promotional text (170 chars, editable post-release without re-review), what's new in version (4000 chars). Frame in server-agnostic terms: "self-hosted libraries that speak OPDS / KOSync / Kobo sync."
- [x] **Privacy policy URL** (live 2026-05-17): https://raphi011.github.io/kios/PRIVACY. Hosted via GitHub Pages on `main` branch root. Set in ASC → App Privacy → Privacy Policy URL **and** in TestFlight Test Information → Privacy Policy URL.
- [x] **Marketing URL** (set 2026-05-17): https://github.com/raphi011/kios (GitHub repo as marketing landing).
- [ ] **Support URL** — public page where users can reach you. GitHub issues page is the simplest choice (https://github.com/raphi011/kios/issues).
- [x] **Description framing** — sync features framed as *optional advanced features*, not headline. Reviewer Notes emphasize local mode + bundled samples.

---

## Phase 1 — Code/config prep — 🟡 MOSTLY DONE

What landed: local EPUB import (1.1), versioning (1.2), export-compliance flag (1.3), privacy manifest (1.4), placeholder app icon (1.6). What's left: an ATS decision (1.5) and the real designed app icon to replace the placeholder (1.6). Phase 1.7 (custom launch screen) is optional.

### 1.1 Local EPUB file import — ✅ DONE

Implemented via `Kios/Services/LocalImportService.swift`, with `.fileImporter` entry points in `Kios/Views/LibraryRootView.swift` (library "+" button) and `Kios/Views/SettingsView.swift`. Also supports inbound `Open in…` via `Kios/Views/RootView.swift:63` (filters on `.epub` path extension) and the `CFBundleDocumentTypes` declaration in `Kios/Info.plist`. Two sample books (`frankenstein.epub`, `moby-dick.epub`) are bundled under `Kios/Resources/SampleBooks/` and seeded on first launch via `AppEnvironment.swift`, so a reviewer can install, launch in airplane mode, and read a book without configuring anything.

### 1.2 Versioning — ✅ DONE

Lives in `Kios/Info.plist` (not `project.yml`, since `INFOPLIST_FILE: Kios/Info.plist` is set): `CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1`. Bump `CFBundleVersion` for every TestFlight upload (App Store Connect rejects duplicate build numbers); bump `CFBundleShortVersionString` for each user-facing release.

### 1.3 Export compliance — ✅ DONE

`ITSAppUsesNonExemptEncryption = false` is set in `Kios/Info.plist:21-22`. The app uses only HTTPS (Apple-provided TLS) and standard system crypto APIs — no custom encryption — so this is accurate. Skips the export-compliance prompt on every TestFlight upload.

### 1.4 Privacy manifest (`PrivacyInfo.xcprivacy`) — ✅ DONE

`Kios/Resources/PrivacyInfo.xcprivacy` declares:
- `NSPrivacyTracking` = `false`, `NSPrivacyTrackingDomains` = `[]`, `NSPrivacyCollectedDataTypes` = `[]`
- `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (access info from the app itself — covers `AuthStore` and the sample-book seed flag in `AppEnvironment`)
- `NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1` (display to user — covers `FileManager.attributesOfItem(atPath:)` in `LibraryRootView`, `HomeRootView`, and `ReaderView`, which surfaces file size in library rows / debug overlays)

Audit confirmed no first-party use of disk-space, system-boot-time, or active-keyboards APIs, so those categories are intentionally omitted. Readium and ZIPFoundation ship their own `PrivacyInfo.xcprivacy` — App Store Connect aggregates all three at upload time.

### 1.5 App Transport Security — ⏳ OPEN (needs decision)

The `README.md` still hedges: "HTTPS strongly recommended either way. Plain HTTP requires an `NSAppTransportSecurity` exception in `Info.plist` for the specific host." No exception is currently in `Kios/Info.plist`. Pick one before submission:

- **Option A — HTTPS-only**: Don't add ATS exceptions. Tighten the README to "HTTPS required". Cleanest review path. Cost: users with HTTP-only home setups need to put a reverse proxy / Tailscale / Caddy in front of their server.
- **Option B — Permissive**: Add `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = true`, plus a justification in App Review Notes ("users connect to self-hosted servers they configure, which may be on local networks without TLS"). Reviewers sometimes accept this for self-hosted-server apps, sometimes don't. Higher review risk.
- **Option C — Per-host exception via UI**: Don't whitelist globally; let users configure the host in-app and add an exception narrowly when they do. Most complex; probably overkill for v1.

### 1.6 App icon assets

The asset catalog uses the **iOS 17+ single-size approach**: one `1024×1024` PNG at `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`, no alpha channel, no transparency, sRGB color space. Xcode auto-generates every smaller variant (20pt/29pt/40pt/60pt iPhone + 76pt/83.5pt iPad) via Lanczos resampling at build time, so the catalog stays a one-file affair.

**Current state — placeholder in place.** A generic icon generated with [IconikAI](https://www.iconikai.com/) (free tier) is wired into the build to unblock Phase 1 validation, simulator installs, and eventually TestFlight internal testing. It is **not** the final brand mark. Free-tier AI generators share a recognisable "AI-generated" aesthetic and won't stand out among the 50+ existing EPUB readers on the App Store. Plan to replace before public launch.

#### AI icon tooling shortlist (evaluated May 2026)

When designing the replacement, three tiers of AI tools are worth knowing about. Mix and match — the model and the asset-packager are separate concerns.

**Tier 1 — All-in-one AI icon generators** (cheapest path, weakest brand differentiation):
- [Recraft](https://www.recraft.ai/generate/icons) — best free-tier *quality*; vector + raster export, brand-style references, editable in Figma after export
- [IconikAI](https://www.iconikai.com/) — used for the current placeholder; 5 generations/day free; auto-exports iOS asset bundles
- [Appicons.ai](https://appicons.ai/) — trained specifically on app-icon shapes; strong rounded-squircle defaults
- [Venngage AI iOS icons](https://venngage.com/ai-tools/ios-app-icon-generator) — Apple HIG defaults baked in

**Tier 2 — General image models** (highest ceiling, more iteration):
- **Flux 2 Pro** (`$0.08/image` via fal.ai, replicate.com) — strongest prompt adherence; ideal for sharp geometric marks
- **Flux 1 Schnell** — free via fal.ai / together.ai / openrouter; same family, lower fidelity
- **Midjourney v7** (`$10/mo` Basic) — best for painterly/illustrative icons; use `--style raw` for cleaner geometric output
- **Ideogram 3** (10/day free) — unbeaten letter rendering; ideal if going with a typographic "K" monogram
- **GPT Image 2** (ChatGPT Plus `$20/mo` or API) — easiest one-shot workflow; output is "good not great"
- **Imagen 4** (Gemini `$20/mo` or Vertex AI) — more suited to scenes than icons

**Tier 3 — Local / open-weight** (free forever, more setup):
- **Flux 2 Klein** + **ComfyUI** — Black Forest Labs open-weights model (Nov 2025); needs ≥12 GB VRAM Nvidia (Apple Silicon works but 3–5× slower)
- **SDXL** — older but mature; many app-icon LoRAs available on Civitai
- **Stable Diffusion 3** — 8 GB VRAM minimum

**Asset packagers** (take any 1024×1024 PNG and produce the Xcode-ready `.appiconset`):
- [icon.kitchen](https://icon.kitchen/) — free, no signup, drag-drop, exports `AppIcon.appiconset` directly
- [appicon.co](https://www.appicon.co/) — browser-only equivalent
- [AppIconKitchen](https://www.appiconkitchen.com/) — bundles AI concept generation + Xcode/Android/PWA export in one tool

For the iOS 17+ single-size approach already in use, the packager step is optional: you can drop a `1024×1024` PNG and the minimal `Contents.json` directly into the existing `AppIcon.appiconset/` folder and Xcode handles the rest.

#### Design constraints (Apple-imposed)

- **No alpha channel.** AI tools often output PNGs with alpha; verify with `sips -g hasAlpha icon.png` (must say "no"). Strip alpha with `sips -s format png -s formatOptions normal icon.png` or Preview → Export → Alpha: off.
- **sRGB colour space.** Most AI output is already sRGB; verify same way (`sips -g space`).
- **No corner radius in the source.** iOS applies its squircle mask at render — your source must be a square canvas. Pre-rounded corners get double-rounded and look broken.
- **No "iOS-style" mimicry.** Skip drawn bezels, drop shadows, 3D highlights. iOS 18+ tinted-icon mode flattens these and they collapse visually.
- **For iOS 18+ tinted-icon support**, also export a single-colour silhouette variant (most AI tools won't generate this — derive in Figma from the colour version).
- **No "EPUB" text or marketing copy on the icon** (Guideline 4.1 / icon-as-marketing rejection).
- **Avoid the system Books app aesthetic** (Guideline 4.1 copycats).
- **Test at 60×60pt early.** AirDrop the 1024 PNG to a real iPhone and view at thumbnail size. Detail that reads at 1024 disappears at 60pt — the #1 cause of "looked great in Figma, looks blobby on iPhone."

#### Recommended replacement workflow (when ready)

1. Generate concept variants in **Ideogram 3** (free) — Kios is a coined word, so a typographic "K" mark is the strongest brand direction and Ideogram leads on letter rendering.
2. Generate parallel concepts in **Recraft** (free) with the "Flat icon" or "Vector" style preset to explore non-typographic alternatives.
3. Refine the chosen direction in **Flux 2 Pro** (~`$1.60` total across ~20 iterations) for prompt-precise tuning of the final master.
4. Polish in Affinity Designer or Figma — strip alpha, force sRGB, export 1024×1024 PNG.
5. Drop the PNG into `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` (replacing the IconikAI placeholder). Done — no `Contents.json` changes needed.

### 1.7 Launch screen

Auto-generated is fine for v1 but looks generic. Optionally add a `LaunchScreen.storyboard` with the app icon centered on a brand color. Not blocking for submission.

### 1.8 Files to touch (remaining work only)

| File | Change |
|---|---|
| `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | Replace the IconikAI placeholder with the real designed mark before public launch |
| `Kios/Info.plist` | Optionally add `NSAppTransportSecurity` per Phase 1.5 decision |
| `README.md` | Tighten to "HTTPS required" if Option A wins; otherwise leave as-is |

Items completed earlier (no further action needed): `project.yml` (bundle ID, dev team, resources path), `Kios/Info.plist` (versioning, encryption flag, EPUB document types), `Kios/Resources/PrivacyInfo.xcprivacy`, `Kios/Services/LocalImportService.swift` and related views.

---

## Phase 2 — Apple Developer Program enrollment — ✅ DONE

Team `KVS38S75S8` is enrolled and wired into `project.yml:14`. Renewal note: Developer Program membership is $99/year recurring — set a calendar reminder for the renewal date so the account doesn't lapse and pull the app from sale.

---

## Phase 3 — App Store Connect setup — ✅ DONE for TestFlight (marketing assets for App Store proper still pending)

All app-record metadata that gates external Beta App Review is complete as of 2026-05-17. The remaining App Store assets (screenshots, marketing copy) are not required for TestFlight and are scheduled under Phase 6.

- [x] **Register the bundle ID** — `com.raphi011.kios` is registered.
- [x] **Create the app record** — name `Kios Reader`, bundle ID `com.raphi011.kios`.
- [x] **App Information** (2026-05-17): Primary *Books*, Secondary *Productivity*, Content Rights = No (no third-party content distributed by the app; bundled samples are public domain). Age Rating = 4+ globally.
- [x] **Pricing & Availability** (2026-05-17): Free ($0.00) in 175 regions, Worldwide availability.
- [x] **App Privacy** (PUBLISHED 2026-05-17): "Data Not Collected". Privacy Policy URL: https://raphi011.github.io/kios/PRIVACY. Truthful: no analytics, no server-side telemetry, all sync traffic goes to the user's own configured server.
- [ ] **(Optional) Create an App Store Connect API key** at App Store Connect → Users and Access → Integrations → App Store Connect API. Generate a `.p8` key, save it (download is one-time only), note the Issuer ID and Key ID. Needed for fastlane/CI uploads.

---

## Phase 4 — Signing, archive, upload — ✅ DONE (one-shot setup; repeat per upload)

Automatic signing is in place and uploads succeed. The recurring workflow per TestFlight build:

1. Bump `CFBundleVersion` in `Kios/Info.plist` (App Store Connect rejects duplicate build numbers).
2. Archive: Xcode → Product → Archive. CLI equivalent:
   ```bash
   xcodebuild -project Kios.xcodeproj -scheme Kios \
     -configuration Release -archivePath build/Kios.xcarchive archive
   ```
3. Validate the archive against App Store Connect from the Organizer (catches metadata/signing issues before upload).
4. Upload via Organizer → Distribute App → App Store Connect → Upload. (Fastlane / `xcrun altool` / `notarytool` are optional later automation.)

Note: there is no `.xcworkspace` here — `make xcodegen` generates `Kios.xcodeproj` directly, and Swift packages resolve as project dependencies.

---

## Phase 5 — TestFlight beta — ✅ INTERNAL DONE; 🟡 EXTERNAL SUBMITTED 2026-05-18 (awaiting Beta Review approval)

Internal testing live since 2026-05-14. External Beta App Review submitted 2026-05-18 for build 1.0(21) and group `Public Beta`.

- [x] Build processed by App Store Connect.
- [x] Internal tester(s) installed via TestFlight app.
- [x] **Test Information** filled out and saved (2026-05-17). Fields: Beta App Description, Feedback Email (raphi011@gmail.com), Marketing URL (https://github.com/raphi011/kios), Privacy Policy URL, Contact info (Raphael Gruber + phone), Review Notes (emphasize local mode + bundled samples; sync optional and not required for review). Sign-in required: **unchecked**.
- [ ] **Real-device coverage** — confirm at least one iPhone *and* one iPad have been used end-to-end: cold launch, local EPUB import, server-backed library sync, reading a book, progress persistence, killing and relaunching, offline behavior, iOS rotation, dark mode.
- 🟡 **External testing** (Beta App Review submitted 2026-05-18, ~24h Apple turnaround):
  - **Public Beta** external group created (ASC TestFlight → External Testing → `Public Beta`).
  - Build 1.0(21) added to Public Beta group on 2026-05-18 and submitted for Beta App Review the same day. Status: "Waiting for Review" → expected "In Review" within hours → "Ready to Test" on approval.
  - After approval, invite testers via the group page → Invite Testers (public link or email; up to 10,000 external testers).
  - Note: bumping `CFBundleShortVersionString` (marketing version, e.g. 1.0 → 1.1) re-triggers Beta Review; bumping only `CFBundleVersion` (build number) within the same marketing version usually doesn't. Stay on `1.0` build N+1, N+2… while iterating with external testers to avoid per-build re-review.
- [ ] Iterate: each fix → bump build number → re-archive → re-upload → re-test. TestFlight builds expire after 90 days.

### Build-eligibility gotcha (learned 2026-05-18)

**TestFlight build eligibility for external testing is captured at upload time, not retroactively.** Builds 1.0(16)–1.0(20) were uploaded *before* full App Information / Pricing / App Privacy were complete. Even after filling all of those in, those builds remained internal-only ("Testing" status) and refused to appear in the external group's build picker — neither the *group→Add Build* picker nor the *build→Add Group* picker would surface the external relationship.

The fix: re-archive and upload as build 1.0(21) *after* all app-record metadata is in place. The fresh upload gets `Ready to Submit` status (yellow dot) and is eligible for external Beta App Review.

**Implication for future TestFlight uploads on this app record**: complete every prerequisite below *before* the upload, not after.

### Verified prerequisites for external Beta App Review

The doc previously listed only five prereqs. Empirically, **all of these must be in place before the upload that you intend to submit externally**:

1. ✅ Hosted Privacy Policy URL (Phase 0b)
2. ✅ Test Information saved in TestFlight tab (Beta App Description, Feedback Email, Marketing URL, Privacy Policy URL, Contact info **including phone number** — ASC rejects empty phone)
3. ✅ App Privacy questionnaire **published** in ASC ("Data Not Collected"; Publish button must be clicked, not just Save)
4. ✅ **App Information**: Category (Primary + Secondary), Content Rights, Age Rating questionnaire (4+ for a reader app with no objectionable content)
5. ✅ **Pricing & Availability**: at least one price tier ($0.00 for free) and at least one country (worldwide is simplest)
6. ✅ External testing group created (`Public Beta`)
7. ✅ "What to Test" notes saved on the specific build before submission
8. ✅ Sign-In Information modal during submission: **uncheck** "Sign-in required" since local mode covers reviewer's full path

If any of #1–#5 are missing at upload time, the build's eligibility is locked to internal-only and a re-upload is required.

---

## Phase 6 — App Store submission

- [ ] **Screenshots**: required sizes for iOS 17+ are **6.9" iPhone** (e.g., iPhone 16 Pro Max, 1290×2796) and **13" iPad** (e.g., iPad Pro M4, 2064×2752) — Apple auto-scales these to all smaller sizes. Min 3, max 10 per device class. Use real app screens, not mockups. Tools: SimGenie, fastlane snapshot, or take from a real device. Consider one "what is this app" screenshot, one local-files screenshot, one server-backed library screenshot, one reading-view screenshot, one settings screenshot.
- [ ] **App preview video** (optional, 15–30 sec, captured from device): skippable for v1.
- [ ] **App Review Information**:
  - Sign-in required? Mark "Sign-in required: No" and write in **Notes**: *"The app's primary mode (local EPUB reading) works fully offline with no account. Two sample books (Frankenstein, Moby-Dick) are bundled and auto-seeded on first launch. Optional sync features (OPDS catalogue browsing, KOSync reading-progress sync, Kobo sync protocol) connect to a server the user configures in Settings — the developer does not operate a backend. These features are not required to evaluate the app and can be skipped for review."*
  - Contact info: phone, email.
- [ ] **Version Release**: choose Manual ("I'll release it when I'm ready"), Automatic ("release as soon as approved"), or Phased (7-day staged rollout to % of users). **Recommended for v1: Manual** — gives you a chance to post a social announcement at launch.
- [ ] **Select the build** (promote the TestFlight build that's baked).
- [ ] **Submit for Review**. Typical review time: **24–48 hours** (often <24, occasionally a week if backed up around holidays). You'll get email updates: "In Review" → "Pending Developer Release" (if Manual) or "Ready for Sale" (if Automatic).

---

## Phase 7 — Likely rejections and how to handle them

Rejections are normal; the goal is to fix them fast.

| Guideline | How it bites this app | Mitigation |
|---|---|---|
| **2.1 — App Completeness** | Reviewer can't get past a "set up server" screen | Local EPUB import (Phase 1.1) makes this near-impossible |
| **4.2 — Minimum Functionality** | "This is just a wrapper around a self-hosted server" | Highlight Readium-based reader, themes, fonts, progress, local files in description |
| **5.1.1 — Data Collection and Storage** | Privacy policy missing or vague | Explicit policy: "No data leaves your device except to servers you configure" |
| **5.1.2 — Data Use and Sharing** | App Privacy declaration doesn't match behavior | Truthfully declare "Data Not Collected" (you don't) |
| **3.1.1 — In-App Purchase** | "Users buy books on a third-party site" | Only an issue if you sell content. Source servers are the user's *own* library → safe. Don't add any "Buy more books" links to external stores. |
| **4.3 — Spam** | "There are already 50 EPUB readers" | Your USP is "works with your self-hosted library + cross-device sync." Lead with that in description. |
| **2.5.1 — Software Requirements / private APIs** | None expected; Readium and ZIPFoundation are public | n/a |
| **NSAppTransportSecurity rejection** | Plain HTTP exception triggers "explain why you need cleartext" | Either go HTTPS-only (Phase 1.5 option A) or write a strong justification |

When rejected: respond in App Store Connect → Resolution Center within a day. Polite, specific, and **with a screen recording** if disputing. Most disputes succeed if the reviewer misunderstood.

---

## Effort estimate (remaining)

| Phase | Effort | Wall clock |
|---|---|---|
| 0a. Name & bundle ID | ✅ done | — |
| 0b. Subtitle + marketing copy + support URL | 0.5–1 day of writing | Async |
| 1. Code prep (local files + privacy + version + encryption) | ✅ done | — |
| 1.5 ATS decision | ~30 min once decided | Same day |
| 1.6 Real app icon (replacing placeholder) | 0.5–1 day | Async |
| 2. Apple Dev enrollment | ✅ done | — |
| 3. App Store Connect listing metadata (categories, age rating, App Privacy, pricing) | ✅ done 2026-05-17 | — |
| 4. Archive + upload | ✅ done; recurring 30 min per build | Same day |
| 5. TestFlight beta | ✅ internal live; 🟡 external submitted 2026-05-18 (~24h Apple review) | ~24h Beta Review + real-device baking |
| 6. Screenshots (6.9" iPhone + 13" iPad) + submission | 0.5–1 day | Same day to submit |
| 7. Review wait | n/a | 24–48 hrs typical |
| **Total remaining** | **~1–2 dev days of work** | **~1 week elapsed** to public launch (after external TF approval) |

---

## Critical files (remaining changes)

| Path | Purpose |
|---|---|
| `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | Replace IconikAI placeholder with the real designed mark |
| `Kios/Info.plist` | Optionally `NSAppTransportSecurity` once Phase 1.5 is decided; bump `CFBundleVersion` per upload |
| `README.md` | Tighten HTTPS guidance to match the Phase 1.5 decision |
| `fastlane/` (optional, NEW) | Automated upload pipeline — not required for v1 |

Already in their final v1 shape (no further action needed): `project.yml`, `Kios/Resources/PrivacyInfo.xcprivacy`, `Kios/Services/LocalImportService.swift`, `Kios/Views/LibraryRootView.swift`, `Kios/Views/SettingsView.swift`, `Kios/Views/RootView.swift`, `Kios/App/AppEnvironment.swift`, sample books under `Kios/Resources/SampleBooks/`, `PRIVACY.md` (hosted), `BETA.md` (pasted into ASC), `CLAUDE.md`/`README.md` (rewritten 2026-05-17 to use generic protocol names).

## Definition of "done" per phase (verification rubric)

- **Phase 1 done** ✅ — build produces a valid `.app` / `.ipa` with placeholder icon, correct version, privacy manifest bundled, and local EPUB import works end-to-end on a simulator with airplane mode on. (Real icon is the only Phase 1 item still outstanding before public launch.)
- **Phase 2 done** ✅ — Team ID `KVS38S75S8` active.
- **Phase 3 done** ✅ — Categories, Content Rights, Age Rating, Pricing & Availability, App Privacy all set 2026-05-17. App Store marketing copy + screenshots tracked under Phase 6, not Phase 3.
- **Phase 4 done** ✅ — build appears under TestFlight → Builds with status "Ready to Test."
- **Phase 5 done** 🟡 — internal complete; external Beta App Review submitted 2026-05-18 for build 1.0(21). Fully done when build status flips to "Ready to Test" externally AND you've installed from TestFlight on a real iPhone *and* iPad, used it for a full day, and found no crashes.
- **Phase 6 done** when status is "Waiting for Review" → "In Review" → "Ready for Sale" (or "Pending Developer Release" if manual).

---

## What this guide deliberately does **not** cover

- **Detailed implementation of local EPUB import** — that needs its own design pass once we agree it's the right shape.
- **Fastlane/CI setup** — useful but not required for v1; ship manually first, automate later.
- **Localization** — not required for v1; can be added post-launch.
- **In-App Purchase / paid tier** — out of scope.
- **Universal Links / SiriKit / WidgetKit** — out of scope.

Each of the above is a follow-up planning task when the time comes.

## Suggested next steps (ordered by blocking impact)

1. **Wait for Beta App Review approval** (~24h from 2026-05-18) — once `Public Beta` becomes "Ready to Test", invite testers from the group page (public link or email up to 10,000). No action required from us in the meantime; Apple emails on status change.
2. **Decide ATS direction** (Phase 1.5) — HTTPS-only vs `NSAllowsArbitraryLoads`. Tightening to HTTPS-only is the cleanest review path; the README's hedge needs to match whichever choice wins.
3. **Real app icon** (Phase 1.6) — the IconikAI placeholder is fine for TestFlight but is the single visible "this is unfinished" signal at public launch. Workflow recommendation: Ideogram 3 + Recraft for concept variants → Flux 2 Pro for refinement → Affinity/Figma polish → drop into `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`.
4. **Real-device baking** (Phase 5) — install from TestFlight on a real iPhone + iPad after external approval, run for a full day, watch for crashes/regressions before promoting to App Store review.
5. **Marketing copy** (Phase 0b) — subtitle (≤30 chars), short description (170), full description (4000), keywords (100), promotional text (170), what's new in version (4000). Keep server-agnostic framing.
6. **Screenshots** (Phase 6) — 6.9" iPhone (1290×2796) + 13" iPad (2064×2752), 3–10 per device class. Consider: hero "what is this app", local-files import, server-backed library, reading view, settings.
7. **Final App Store submission** (Phase 6).
