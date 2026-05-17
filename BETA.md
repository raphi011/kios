# TestFlight — Beta Testing Notes

Thanks for helping test Kios. The app is a native iOS reader for a
self-hosted Calibre-Web-Automated (CWA) server. You will need a CWA
instance you can reach from your device (HTTPS strongly recommended).

## What to test

### Setup
- [ ] Add a CWA server in **Settings**: URL, username, password
- [ ] Pick sync protocol: **kosync** (KOReader) or **Kobo**
  - kosync: same `/opds` credentials are reused for `/kosync`
  - Kobo: paste the sync URL from your server's admin panel
- [ ] Confirm the library populates after a refresh

### Library
- [ ] Browse the catalogue (list and gallery modes)
- [ ] Search by title / author
- [ ] Cover thumbnails load and stay cached after relaunch
- [ ] Download an EPUB — progress shows, file lands locally
- [ ] Import a local `.epub` via Files / share sheet

### Reader
- [ ] Open a downloaded book
- [ ] Page forward / backward; chapter navigation via ToC
- [ ] Change font size, theme (light / sepia / dark), typography
- [ ] Select text — selection doesn't dismiss the reader
- [ ] Bookmark a location; verify it persists across relaunch

### Sync
- [ ] Read a few pages; force-quit; relaunch — position restored
  locally
- [ ] Read on another device pointed at the same server; verify
  positions converge (give it a few seconds)
- [ ] Switch sync protocol in Settings — verify no data loss on the
  active server

### General
- [ ] Light + dark mode
- [ ] iPhone portrait, iPhone landscape, iPad split-view
- [ ] Background → foreground transitions; no jank, no lost state
- [ ] Airplane-mode → fully offline reading works; reconnects sync on
  network return

## What we already know about

- First build after a long pause may take a moment to re-resolve
  reading positions on the server.
- Plain-HTTP servers won't connect without an ATS exception baked
  into the build. Use HTTPS.

## How to report issues

Reply to the TestFlight invite email, or:

- **Crashes**: TestFlight collects them automatically — please tap
  "Share with Developer" when prompted.
- **Bugs / weirdness**: include device model, iOS version, build
  number (Settings → About), and a short repro.
- **Logs**: Settings app → Privacy & Security → Analytics &
  Improvements → Analytics Data, filter by `Kios`, share via mail.

Email: raphi011@gmail.com
