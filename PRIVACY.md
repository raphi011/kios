# Privacy Policy

_Last updated: 2026-05-17_

Kios is a self-hosted EPUB reader. The app connects only to the
Calibre-Web-Automated (CWA) server **you** configure in Settings.
The developer does not operate any backend.

## What Kios collects

**Nothing.** Kios contains no analytics, telemetry, advertising SDKs,
crash reporters, or third-party tracking of any kind.

Apple may report aggregated, anonymised crash and usage data to the
developer through App Store Connect if you have opted in via
**Settings → Privacy & Security → Analytics & Improvements** on your
device. That sharing is controlled entirely by iOS, not by Kios.

## What stays on your device

- Library metadata, reading positions, bookmarks, and app settings —
  stored in the local SwiftData database.
- Book files (`.epub`) downloaded from your CWA server — stored in the
  app's sandbox.
- Cover thumbnails — cached locally.
- Server credentials — stored in the iOS Keychain.

## What leaves your device

Kios makes network requests **only** to:

1. **The CWA server URL you enter in Settings**, for:
   - OPDS catalogue browsing and EPUB downloads
   - Reading-progress sync (KOReader `kosync` protocol or Kobo sync
     protocol, depending on which you configure)
   - Cover image fetches

2. **No other hosts.** No first- or third-party analytics, no remote
   configuration, no telemetry endpoint.

Your CWA server has its own privacy policy and operator. Kios is not
responsible for what your server logs or stores.

## Children

Kios is not directed at children under 13 and collects no data, so no
COPPA-relevant processing occurs.

## Changes

Material changes will be reflected in this file with a new "Last
updated" date.

## Contact

raphi011@gmail.com
