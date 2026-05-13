# App Store Publishing Guide

> Reference document covering everything required to take this app from "builds locally" to "live on the App Store." Each phase is independent and can be executed on its own schedule; the order roughly matches the dependency graph (Phase 0 decisions feed Phase 3 setup, etc.).

## Context

This iOS app — codenamed `ios-reader` in the repo, product name **Kios** — is a native SwiftUI + SwiftData EPUB reader (iOS 17+, iPhone + iPad) that talks to self-hosted Calibre-Web/CWA servers and supports KOSync/Kobo sync. It's well-tested (168 tests passing) and feature-complete on the `feat/v1` branch, but **not yet ready for App Store submission**: no Apple Developer account, no signing team, no version numbers, no app icon, no privacy manifest, no App Store Connect record, no screenshots, no marketing copy.

This document captures the full set of requirements, decisions, and process steps so future submission work has a single reference.

## Key decisions captured so far

- **App name**: **Kios**. App Store listing name: **Kios Reader** (the "Reader" descriptor differentiates Class 9 goods from the existing *Kios, Inc.* mark and adds modest ASO weight). Home-screen `CFBundleDisplayName` stays as **Kios**. Treated as a coined word — no public reference to the Kobo+iOS etymology in marketing, store copy, or readme. Project is free + open source + niche, so the residual risks (kiosk search-collision, low-probability C&D from Kios, Inc.) are recoverable rather than existential. See "Phase 0a — Picking a name" for the analysis trail (including the rejected *Aldus* alternative).
- **Bundle ID**: `com.raphi011.kios`. Locked. Matches the GitHub-handle namespace; short and ages well. Replaces the working-title `me.iosreader.iOSReader`.
- **Apple Developer enrollment**: deferred until the app is "ready to launch."
- **Reviewer access strategy**: add local EPUB file import so the app is fully testable offline; demo Calibre-Web server credentials in App Review Notes as backup.
- **Visual assets**: still need designed mark + screenshots. A **placeholder icon from [IconikAI](https://www.iconikai.com/) is wired into the build** (`Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`) so the simulator install + Xcode validation pipelines work end-to-end today. The placeholder **must be replaced with a real designed mark before public launch** — see "1.6 App icon assets" for the AI tooling shortlist evaluated during the placeholder pass.
- **Submission path**: TestFlight beta first, then promote to App Store review.

## Current state (verified via codebase exploration)

| Area | Status |
|---|---|
| Bundle ID | `me.iosreader.iOSReader` (in `project.yml`) |
| Deployment target | iOS 17+, iPhone + iPad |
| Code signing | `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = ""` (unset) |
| Versioning | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` **not set** (uses auto-Info.plist) |
| App icon | **Placeholder** — IconikAI 1024×1024 single-size master at `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. To be replaced before public launch. |
| Launch screen | Auto-generated (generic) |
| Privacy descriptions in Info.plist | None (app uses no camera/photos/location/tracking) |
| `PrivacyInfo.xcprivacy` | **Missing** |
| `ITSAppUsesNonExemptEncryption` | Not set (export-compliance prompt blocks every TestFlight build until this is in Info.plist) |
| `NSAppTransportSecurity` | Not configured (README mentions HTTPS-only; HTTP needs ATS exception) |
| Capabilities/entitlements | None declared (no iCloud, push, IAP, App Groups, Sign in with Apple) |
| Third-party SDKs | Readium (swift-toolkit), ZIPFoundation; **no analytics, no ad SDKs, no trackers** |
| CI/CD | Makefile only; no fastlane, no GitHub Actions, no `ExportOptions.plist` |
| App Store Connect metadata | None (no `fastlane/metadata/`, no `marketing/`) |

---

## Phase 0a — Picking a name

The current `iOSReader` working title is generic, low-distinctiveness in App Store search, and ineligible for trademark protection. Apple also rejects names that are descriptive-only (Guideline 4.1 "Copycats" treats generic device-prefixed names as low-quality). A real name is needed **before** Phase 0b, because the choice cascades into bundle ID, App Store Connect record, domain, privacy policy URL, marketing copy, and icon design.

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

- [ ] **Confirm bundle ID** to match the chosen name (see Phase 0a). **Important: once you upload the first build to App Store Connect, this ID is locked forever** — you can never rename it, only retire it.
- [ ] **App display name** — the name from Phase 0a (currently **Aldus**), plus a **subtitle** (up to 30 chars) that appears under the name in the App Store listing. Example: "Aldus — Self-hosted EPUB reader" or "Aldus — Your library, beautifully read".
- [ ] **Primary category + secondary category** — likely Primary: *Books*, Secondary: *Productivity*.
- [ ] **Pricing model** — free, paid, or free with IAP? (IAP requires StoreKit work; free is simplest for v1.)
- [ ] **Age rating** — App Store Connect asks a 20-question questionnaire. Likely 4+ for this app.
- [ ] **Marketing copy**: short description (170 chars), full description (4000 chars), keywords (100 chars), promotional text (170 chars, editable post-release without re-review), what's new in version (4000 chars).
- [ ] **Privacy policy URL** — Apple requires a public URL. A static page on GitHub Pages or your domain is fine. Must declare what data the app collects (in your case: nothing leaves the device except to user-configured servers).
- [ ] **Support URL** — public page where users can reach you (GitHub issues page works).
- [ ] **Description framing** — frame Calibre-Web/Kobo sync as *optional advanced features*, not headline. See "Risks" section below.

---

## Phase 1 — Code/config prep (still no Apple account needed)

These changes get the codebase to a state where, the moment you have a Developer team ID, you can archive and upload.

### 1.1 Local EPUB file import (the new feature you want)

Add a "Open file…" / Files-app integration so users (and Apple reviewers) can read EPUBs without setting up a server. This is the **single highest-impact change** for review approval.

- New screen entry point: a button/menu item in the library view that opens `UIDocumentPickerViewController` with content types `[.epub]` (and `.pdf`, `.cbz` if you want, though README notes only EPUB has a reader).
- On pick: copy the file into the app's sandbox (`Application Support/LocalBooks/`), parse metadata with Readium's `Publication.OpeningParser`, and insert a `BookEntity` into SwiftData with `source: .local`.
- Support iOS Share Sheet entry too (`UIDocumentInteractionController` / `Open in…` from Mail/Safari/Files) by declaring the EPUB UTI in `Info.plist`:
  - `CFBundleDocumentTypes` → EPUB (`org.idpf.epub-container`)
  - `LSItemContentTypes` likewise
- Make sure the local books path appears in the same library list as Calibre-Web books, with a small badge/icon to distinguish source.
- Test: the app must be fully usable end-to-end with zero network — fresh install → import EPUB → read → close → reopen → progress preserved.

This belongs in its own implementation plan, but flagging it here because **the submission depends on it**.

### 1.2 Versioning

In `project.yml`, add to the `iOSReader` target's `settings.base:`
```yaml
MARKETING_VERSION: "1.0"
CURRENT_PROJECT_VERSION: "1"
```
Then `make xcodegen`. Bump `CURRENT_PROJECT_VERSION` for every TestFlight upload (App Store Connect rejects duplicate build numbers); bump `MARKETING_VERSION` for each user-facing release.

### 1.3 Export compliance

Add to Info.plist (via `project.yml` `INFOPLIST_KEY_*` or a real Info.plist):
```
ITSAppUsesNonExemptEncryption = false
```
Reasoning: the app uses only HTTPS (Apple-provided TLS) and standard system crypto APIs — no custom encryption. This single key skips the export-compliance prompt on every TestFlight upload. If you ever ship custom crypto, you'll need to set it to `true` and file an ECCN — not the case here.

### 1.4 Privacy manifest (`PrivacyInfo.xcprivacy`)

Apple **requires** this since May 2024 for apps that use any of the "Required Reason APIs" (`NSPrivacyAccessedAPITypes`). The Core package likely uses some of these (UserDefaults, file timestamps, disk space, system boot time). Create `iOSReader/Resources/PrivacyInfo.xcprivacy` with:
- `NSPrivacyTracking` = `false`
- `NSPrivacyTrackingDomains` = `[]`
- `NSPrivacyCollectedDataTypes` = `[]` (you don't collect anything in the Apple sense — user-entered server URLs/credentials stored in keychain don't count as "data collection")
- `NSPrivacyAccessedAPITypes` = list each API category you use with a reason code. Likely entries: `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`), `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1` or `DDA9.1`), `NSPrivacyAccessedAPICategoryDiskSpace` (reason `E174.1`), `NSPrivacyAccessedAPICategorySystemBootTime` (reason `35F9.1`).

Audit `Core/Sources/` and `iOSReader/` for `Date()`/`FileManager.attributesOfItem`/`UserDefaults`/`ProcessInfo.systemUptime` calls to confirm. Readium and ZIPFoundation already ship their own `PrivacyInfo.xcprivacy` (you confirmed this in build artifacts) — yours covers only first-party code.

### 1.5 App Transport Security

The README says HTTP needs an exception. Two options:
- **Recommended**: Don't add ATS exceptions. Require HTTPS. Document in the README/setup that users must serve Calibre-Web over HTTPS. Apple grants HTTPS-only apps the cleanest review.
- **Permissive**: Add `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = true`. This **requires a justification in App Review Notes** ("users connect to self-hosted servers they configure, which may be on local networks without TLS"). Reviewers sometimes accept this for self-hosted-server apps, sometimes don't. Higher review risk.

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

### 1.8 Files to touch

| File | Change |
|---|---|
| `project.yml` | Add `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, eventually `DEVELOPMENT_TEAM`. Add `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: false`. Add `sources:` entry for new `Resources/` folder. |
| `iOSReader/Resources/PrivacyInfo.xcprivacy` (NEW) | First-party privacy manifest |
| `Kios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` | App icon (currently the IconikAI placeholder; replace before launch) |
| `iOSReader/App/` — new view for document picker | Local file import UI |
| `Info.plist` keys via `project.yml` | `CFBundleDocumentTypes` for EPUB; optionally `NSAppTransportSecurity` |
| `README.md` | Document HTTPS-only requirement (if going that route) |

---

## Phase 2 — Apple Developer Program enrollment

When you're ready to ship. Allow **1–3 days** end-to-end.

- [ ] Sign in at [developer.apple.com](https://developer.apple.com) with a personal Apple ID; enable two-factor auth (required).
- [ ] Enroll in the Apple Developer Program — $99/year, **annual recurring**, charged immediately. Individual vs Organization: individual is faster (no D-U-N-S required) but your developer name shows as your legal name on the App Store listing. Organization requires a D-U-N-S number (free to request from Dun & Bradstreet, can take a week) and shows your company name.
- [ ] Apple verifies the enrollment (24–48hr typical, can be slower).
- [ ] Once approved: note your **Team ID** (10-character alphanumeric) — visible at developer.apple.com → Membership. You'll plug this into `project.yml` as `DEVELOPMENT_TEAM`.

---

## Phase 3 — App Store Connect setup

After enrollment, log in to [appstoreconnect.apple.com](https://appstoreconnect.apple.com).

- [ ] **Register the bundle ID** at developer.apple.com → Certificates, IDs & Profiles → Identifiers → "+" → App IDs → App. Use the bundle ID decided in Phase 0a (e.g., `com.raphaelgruber.aldus`) — **not** the working-title `me.iosreader.iOSReader`. Enable only the capabilities you actually use (currently none).
- [ ] **Create the app record** in App Store Connect → My Apps → "+" → New App. Platform: iOS. Name: the App Store name (e.g., `Aldus`). Primary language. Bundle ID: select the one you just registered. SKU: any unique string (e.g., `aldus-1`).
- [ ] **App Information**: category (Books / Productivity), content rights ("Does your app contain, show, or access third-party content?" — yes if Calibre-Web is treated as third-party; the safer answer is yes with the user-supplied-URL justification), age rating questionnaire (20 questions, fill honestly — expect 4+).
- [ ] **Pricing & Availability**: free vs paid tier, countries/regions.
- [ ] **App Privacy**: declare data types collected. For ios-reader: select "Data Not Collected" if no analytics and no server side telemetry. Even with Calibre-Web sync, the data goes to the user's own server, not yours, so it's not "collected by the developer."
- [ ] **(Optional) Create an App Store Connect API key** at App Store Connect → Users and Access → Integrations → App Store Connect API. Generate a `.p8` key, save it (download is one-time only), note the Issuer ID and Key ID. Needed for fastlane/CI uploads.

---

## Phase 4 — Signing, archive, upload

- [ ] In `project.yml`, set `DEVELOPMENT_TEAM` to your Team ID. Run `make xcodegen`.
- [ ] In Xcode: open `iOSReader.xcworkspace`, select the iOSReader target → Signing & Capabilities → confirm "Automatically manage signing" is checked, team is selected. Xcode auto-creates the distribution certificate and provisioning profile on demand.
- [ ] Verify build number is unique (`CURRENT_PROJECT_VERSION` higher than the last upload).
- [ ] Archive: Xcode → Product → Archive (must be a real device or "Any iOS Device (arm64)" — not a simulator). Equivalent CLI:
  ```bash
  xcodebuild -workspace iOSReader.xcworkspace -scheme iOSReader \
    -configuration Release -archivePath build/iOSReader.xcarchive archive
  ```
- [ ] Validate the archive against App Store Connect from the Organizer (catches metadata/signing issues before upload).
- [ ] Upload via Organizer → Distribute App → App Store Connect → Upload. Or via CLI with an `ExportOptions.plist` and `xcrun altool` / `notarytool`. Or via fastlane (`pilot upload`).

---

## Phase 5 — TestFlight beta

- [ ] Wait for App Store Connect to process the build (5–30 min usually; sometimes hours).
- [ ] Fill out **Test Information** in TestFlight tab: beta app description, email, marketing URL, privacy policy URL.
- [ ] **Internal testing** (no Apple review): add up to 100 internal testers (must be members of your Developer team). Install via TestFlight app immediately.
- [ ] Test on **real devices** — at minimum one iPhone and one iPad. Verify: cold launch, local EPUB import, Calibre-Web sync, reading a book, progress persistence, killing and relaunching, offline behavior, iOS rotation, dark mode.
- [ ] **External testing** (optional, requires Apple "Beta App Review" — first build only, ~24hr): up to 10,000 testers via public link or email invite. Useful for catching edge cases your devices don't have (older iPhones, locales, accessibility settings).
- [ ] Iterate: each fix → bump build number → re-archive → re-upload → re-test. TestFlight builds expire after 90 days.

---

## Phase 6 — App Store submission

- [ ] **Screenshots**: required sizes for iOS 17+ are **6.9" iPhone** (e.g., iPhone 16 Pro Max, 1290×2796) and **13" iPad** (e.g., iPad Pro M4, 2064×2752) — Apple auto-scales these to all smaller sizes. Min 3, max 10 per device class. Use real app screens, not mockups. Tools: SimGenie, fastlane snapshot, or take from a real device. Consider one "what is this app" screenshot, one local-files screenshot, one Calibre-Web screenshot, one reading-view screenshot, one settings screenshot.
- [ ] **App preview video** (optional, 15–30 sec, captured from device): skippable for v1.
- [ ] **App Review Information**:
  - Sign-in required? If yes (for Calibre-Web testing), provide demo credentials. If you've built local EPUB import per Phase 1.1, mark "Sign-in required: No" and write in **Notes**: *"The app's primary mode (local EPUB reading) works offline with no account. Optional Calibre-Web sync can be tested with the demo server at https://demo.calibre-web.example with username `demo` / password `demo`."*
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
| **3.1.1 — In-App Purchase** | "Users buy books on a third-party site" | Only an issue if you sell content. Calibre-Web is the user's *own* library → safe. Don't add any "Buy more books" links to external stores. |
| **4.3 — Spam** | "There are already 50 EPUB readers" | Your USP is "works with your self-hosted library + cross-device sync." Lead with that in description. |
| **2.5.1 — Software Requirements / private APIs** | None expected; Readium and ZIPFoundation are public | n/a |
| **NSAppTransportSecurity rejection** | Plain HTTP exception triggers "explain why you need cleartext" | Either go HTTPS-only (Phase 1.5 option A) or write a strong justification |

When rejected: respond in App Store Connect → Resolution Center within a day. Polite, specific, and **with a screen recording** if disputing. Most disputes succeed if the reviewer misunderstood.

---

## Effort estimate (calendar time)

| Phase | Effort | Wall clock |
|---|---|---|
| 0. Decisions & copy | 0.5–1 day of writing | Async, do anytime |
| 1. Code prep (local files + privacy + icon + version) | 3–5 dev days | Can start now |
| 2. Apple Dev enrollment | ~30 min of forms | 1–3 days approval wait |
| 3. App Store Connect setup | 1–2 hours | Same day |
| 4. Archive + upload | 30 min once configured | Same day |
| 5. TestFlight beta | 1 hour setup + 1 week real-device baking | 1 week |
| 6. Screenshots + submission | 0.5–1 day | Same day to submit |
| 7. Review wait | n/a | 24–48 hrs typical |
| **Total** | **~7–10 dev days of work** | **~2–3 weeks elapsed** assuming nothing goes sideways |

---

## Critical files that will need changes

| Path | Purpose |
|---|---|
| `project.yml` | Versioning, dev team, Info.plist keys, Resources path |
| `iOSReader/Resources/PrivacyInfo.xcprivacy` (NEW) | Privacy manifest |
| `Kios/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` + `icon-1024.png` | App icon — wired today with IconikAI placeholder; replace `icon-1024.png` before launch |
| `iOSReader/App/` (new files for document picker / local library) | Local EPUB import feature |
| `README.md` | HTTPS-only documentation |
| `fastlane/` (optional, NEW) | Automated upload pipeline |

## Definition of "done" per phase (verification rubric)

- **Phase 1 done** when `make build-ios` produces an `.ipa` with valid app icon, correct version, no warnings about missing privacy manifest, and local EPUB import works end-to-end on a simulator with airplane mode on.
- **Phase 2 done** when you can sign in to App Store Connect.
- **Phase 3 done** when the app record exists and shows "Prepare for Submission" status.
- **Phase 4 done** when the build appears under TestFlight → Builds with status "Ready to Test."
- **Phase 5 done** when you've installed it from TestFlight on a real iPhone *and* iPad, used it for a full day, and found no crashes.
- **Phase 6 done** when status is "Waiting for Review" → "In Review" → "Ready for Sale" (or "Pending Developer Release" if manual).

---

## What this guide deliberately does **not** cover

- **Detailed implementation of local EPUB import** — that needs its own design pass once we agree it's the right shape.
- **Fastlane/CI setup** — useful but not required for v1; ship manually first, automate later.
- **Localization** — not required for v1; can be added post-launch.
- **In-App Purchase / paid tier** — out of scope.
- **Universal Links / SiriKit / WidgetKit** — out of scope.

Each of the above is a follow-up planning task when the time comes.

## Suggested next steps

1. **Trademark clearance for Aldus** — USPTO TESS search in Class 9 (downloadable software) and Class 42 (SaaS); flat-fee attorney review (~$300–500) recommended before any App Store filing. Primary risk: Adobe's legacy Aldus marks (Aldus Corp acquired 1994).
2. **Domain acquisition** — `aldus.com` is parked-for-sale (premium pricing likely); cheaper viable alternatives: `aldus.app` (if buyable from current holder), `aldusapp.com`, `getaldus.com`, `aldus.io`.
3. **Decide individual vs organization Apple Developer enrollment** so you know what info to gather (organization needs a D-U-N-S number).
4. **Sketch the local EPUB import UX** — that becomes the next implementation plan to write, and is the single highest-impact Phase 1 work item for review approval.
