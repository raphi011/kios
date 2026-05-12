import SwiftUI
import SwiftData
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator
import Core

/// Immersive reader. Presented as a `fullScreenCover` from `RootView`.
struct ReaderView: View {
    let bookID: UUID

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @Query private var books: [Book]
    @Query private var downloads: [Download]

    @AppStorage("reader.fontSizePct") private var fontSizePct: Int = 100

    @State private var publication: Publication?
    @State private var initialLocator: Locator?
    @State private var loadError: String?
    @State private var pendingPrompt: PromptInfo?

    /// Drops the navigator's first `locationDidChange` after mount. That
    /// emission is a load artifact ("I've finished initial layout at
    /// `initialLocator`") and carries no new user intent — buffering it
    /// races `resolveOpen` and could push the stale local position over a
    /// peer's newer write on the server.
    @State private var initialEmissionSeen: Bool = false
    /// Set on the first real (post-initial-load) emission. Suppresses any
    /// late-arriving `.applyServer` / `.promptUser` resolution that would
    /// yank the user out of the position they're already reading at.
    @State private var userHasNavigated: Bool = false

    @State private var uiVisible: Bool = false
    @State private var fontHUD: Int? = nil
    @State private var currentLocator: Locator?
    /// Set when the user accepts a cross-device progress prompt. Handed to
    /// `ReaderHost`; the container dedupes by `Locator.jsonString`, so we
    /// don't need to clear it after navigating.
    @State private var pendingJump: Locator?
    /// Whole-book progression (0–1) the user is dragging toward. Non-nil only
    /// while a scrub is in progress; drives both the bar's preview and the
    /// scrub HUD overlay. Set back to nil on commit/cancel.
    @State private var scrubProgress: Double?
    /// Flat list of every Readium position, cached after publication opens.
    /// Used to translate scrub progression → Locator without going through
    /// the publication service on every drag sample.
    @State private var positions: [Locator] = []
    /// TOC entries flattened depth-first and tagged with their starting
    /// totalProgression. Sorted ascending; binary-searched to resolve the
    /// chapter heading for a scrub position.
    @State private var tocProgressions: [(progression: Double, title: String)] = []
    /// Resource path (anchor stripped) → chapter title. Built alongside
    /// `tocProgressions` so the cross-device prompt can name the chapter
    /// a peer is on without re-walking the TOC.
    @State private var tocTitlesByHref: [String: String] = [:]

    init(bookID: UUID) {
        self.bookID = bookID
        let id = bookID
        _books = Query(filter: #Predicate<Book> { $0.id == id })
        _downloads = Query(filter: #Predicate<Download> { $0.bookID == id })
    }

    private var book: Book? { books.first }
    private var download: Download? { downloads.first }

    struct PromptInfo: Identifiable {
        let id = "continue-prompt"
        let local: Double
        let server: CanonicalProgress
        let serverHref: String?
    }

    var body: some View {
        ZStack {
            // EPUB content stretches edge-to-edge for immersive reading;
            // chrome and HUD respect the safe area so they don't draw
            // behind the Dynamic Island / status bar / home indicator.
            content.ignoresSafeArea()
            chromeOverlay
            hudOverlay
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .simultaneousGesture(swipeDownDismissGesture())
        .task(id: book?.fileURL) {
            async let p: Void = loadPublicationIfReady()
            async let r: Void = resolveOpen()
            _ = await (p, r)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await flush() }
            }
        }
        .onDisappear {
            Task { await flush() }
            env.activeReader = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let book {
            if book.fileURL != nil, let publication {
                let id = book.id
                ReaderHost(
                    publication: publication,
                    initialLocator: initialLocator,
                    pendingJump: pendingJump,
                    fontSizePct: fontSizePct,
                    statusBarHidden: !uiVisible,
                    onLocatorChange: { @Sendable locator in
                        Task { @MainActor in
                            currentLocator = locator
                            await pushLocator(bookID: id, locator: locator)
                        }
                    },
                    onCenterTap: { withAnimation(.easeOut(duration: 0.2)) { uiVisible.toggle() } },
                    onPageTurn: {
                        guard uiVisible else { return }
                        withAnimation(.easeOut(duration: 0.2)) { uiVisible = false }
                    },
                    onPinchUpdate: { pct in
                        // Spec: fade-in 0.15s, fade-out 0.3s.
                        let duration = (pct == nil) ? 0.3 : 0.15
                        withAnimation(.easeOut(duration: duration)) { fontHUD = pct }
                    },
                    onPinchCommit: { pct in
                        fontSizePct = pct
                    },
                    onDismissRequested: { dismiss() }
                )
                .alert(item: $pendingPrompt) { info in
                    Alert(
                        title: Text(promptTitle(for: info)),
                        message: Text(relativeReadMessage(for: info.server)),
                        primaryButton: .default(Text("Continue")) {
                            if let locator = parseLocator(info.server.locatorJSON) {
                                pendingJump = locator
                            }
                        },
                        secondaryButton: .cancel(Text("Stay here"))
                    )
                }
            } else if book.fileURL == nil {
                DownloadingView(book: book, download: download)
            } else if let loadError {
                Text(loadError).foregroundStyle(.orange).padding()
            } else {
                ProgressView("Opening…").tint(.white)
            }
        } else {
            Text("Book not found").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chromeOverlay: some View {
        if uiVisible {
            VStack(spacing: 0) {
                ReaderTopBar(title: book?.title ?? "", onClose: { dismiss() })
                Spacer()
                ReaderBottomProgressBar(
                    locator: currentLocator,
                    scrubProgress: scrubProgress,
                    chapterTitle: chapterTitle(at:),
                    onScrubUpdate: { progress in scrubProgress = progress },
                    onScrubCommit: { progress in commitScrub(to: progress) },
                    onScrubCancel: { scrubProgress = nil }
                )
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var hudOverlay: some View {
        if let pct = fontHUD {
            ReaderFontHUD(pct: pct)
                .transition(.opacity)
        } else if let progress = scrubProgress {
            ReaderScrubHUD(progress: progress, chapter: chapterTitle(at: progress))
                .transition(.opacity)
        }
    }

    private func swipeDownDismissGesture() -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let translation = CGSize(width: value.translation.width,
                                         height: value.translation.height)
                let velocity = CGSize(width: value.predictedEndTranslation.width - value.translation.width,
                                      height: value.predictedEndTranslation.height - value.translation.height)
                if SwipeDismissPolicy.shouldDismiss(translation: translation, velocity: velocity) {
                    dismiss()
                }
            }
    }

    private func loadPublicationIfReady() async {
        guard let book, let fileURL = book.fileURL else { return }
        let id = bookID
        if let progress = try? context.fetch(
            FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.bookID == id })
        ).first {
            initialLocator = parseLocator(progress.locatorJSON)
        }
        do {
            let pub = try await openPublication(at: fileURL)
            publication = pub
            await loadScrubMetadata(for: pub)
        } catch {
            let diagnostics = fileDiagnostics(at: fileURL)
            loadError = "Failed to open:\n\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)\n\n\(diagnostics)"
        }
    }

    /// Caches the positions list and TOC→progression map so scrubbing can
    /// resolve progress → Locator and progress → chapter heading without
    /// hitting the publication service on every drag sample. Failures here
    /// degrade gracefully: scrubbing still works (jumps via `positions`) and
    /// the chapter label falls back to an em-dash when TOC is unavailable.
    private func loadScrubMetadata(for publication: Publication) async {
        positions = (try? await publication.positions().get()) ?? []
        let toc = (try? await publication.tableOfContents().get()) ?? []
        let built = buildTOCProgressions(toc: toc, positions: positions)
        tocProgressions = built.progressions
        tocTitlesByHref = built.titlesByHref
    }

    /// Walks the TOC depth-first, mapping each entry to its starting
    /// totalProgression by matching against the first reading-order position
    /// that lives in the same resource. Entries whose href doesn't appear in
    /// the reading order are dropped. Result is sorted ascending so a
    /// linear scan (or future binary search) can find "current chapter" for
    /// a given progression.
    private func buildTOCProgressions(
        toc: [ReadiumShared.Link],
        positions: [Locator]
    ) -> (progressions: [(progression: Double, title: String)], titlesByHref: [String: String]) {
        var flat: [(href: String, title: String)] = []
        func walk(_ links: [ReadiumShared.Link]) {
            for link in links {
                let title = link.title ?? ""
                if !title.isEmpty {
                    flat.append((href: link.href, title: title))
                }
                walk(link.children)
            }
        }
        walk(toc)

        var mapped: [(progression: Double, title: String)] = []
        var titlesByHref: [String: String] = [:]
        for entry in flat {
            // TOC hrefs often include #anchor; positions key on the resource
            // path. Compare resource-only — anchor granularity is not enough
            // to distinguish TOC entries in the typical EPUB.
            let entryResource = entry.href.components(separatedBy: "#").first ?? entry.href
            if titlesByHref[entryResource] == nil {
                titlesByHref[entryResource] = entry.title
            }
            guard let pos = positions.first(where: { $0.href.string.hasSuffix(entryResource) || entryResource.hasSuffix($0.href.string) }),
                  let progression = pos.locations.totalProgression else { continue }
            mapped.append((progression: progression, title: entry.title))
        }
        return (mapped.sorted { $0.progression < $1.progression }, titlesByHref)
    }

    /// Best-effort chapter title for a Kobo `Location.Source` or Readium
    /// `locator.href`. Tolerates the same prefix/suffix ambiguity as
    /// `buildTOCProgressions`, since locator hrefs may be relative to the
    /// EPUB root while TOC entries are relative to wherever the OPF lives.
    private func chapterTitle(forHref href: String?) -> String? {
        guard let href else { return nil }
        let resource = href.components(separatedBy: "#").first ?? href
        if let exact = tocTitlesByHref[resource] { return exact }
        for (tocHref, title) in tocTitlesByHref where resource.hasSuffix(tocHref) || tocHref.hasSuffix(resource) {
            return title
        }
        return nil
    }

    /// Returns the title of the TOC entry that *starts at or before* the
    /// given whole-book progression. Falls back to an em-dash when the TOC
    /// wasn't loaded or the progression precedes the first mapped entry.
    private func chapterTitle(at progression: Double) -> String {
        guard !tocProgressions.isEmpty else { return "—" }
        var match: String?
        for entry in tocProgressions {
            if entry.progression <= progression {
                match = entry.title
            } else {
                break
            }
        }
        return match ?? tocProgressions.first?.title ?? "—"
    }

    /// Translates a whole-book progression into a Readium `Locator` via the
    /// cached positions list and hands it to the navigator through
    /// `pendingJump`. No-ops if positions aren't loaded yet — caller is
    /// responsible for resetting `scrubProgress` afterwards.
    private func commitScrub(to progression: Double) {
        defer { scrubProgress = nil }
        guard !positions.isEmpty else { return }
        let idx = max(0, min(positions.count - 1, Int(round(Double(positions.count - 1) * progression))))
        pendingJump = positions[idx]
    }

    private func fileDiagnostics(at url: URL) -> String {
        var lines: [String] = []
        lines.append("URL: \(url.absoluteString)")
        lines.append("Scheme: \(url.scheme ?? "<none>")")
        lines.append("Path: \(url.path)")
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        lines.append("Exists: \(exists)")
        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                lines.append("Size: \(size) bytes")
            }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let head = handle.readData(ofLength: 4)
                lines.append("Head: \(head.map { String(format: "%02x", $0) }.joined())")
            } else {
                lines.append("Head: <unreadable>")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func openPublication(at url: URL) async throws -> Publication {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        guard let fileURL = FileURL(url: url) else {
            throw OpenError.invalidFileURL(url)
        }

        let asset = try await assetRetriever.retrieve(url: fileURL)
            .mapError { OpenError.asset($0) }
            .get()

        let parser = CompositePublicationParser(EPUBParser())
        let opener = PublicationOpener(parser: parser)

        return try await opener.open(asset: asset, allowUserInteraction: false)
            .mapError { OpenError.publication($0) }
            .get()
    }

    private enum OpenError: LocalizedError {
        case invalidFileURL(URL)
        case asset(AssetRetrieveURLError)
        case publication(PublicationOpenError)

        var errorDescription: String? {
            switch self {
            case .invalidFileURL(let url):
                return "Readium rejected the file URL: \(url.absoluteString)"
            case .asset(let inner):
                return "Asset retrieval failed: \(Self.describe(inner))"
            case .publication(let inner):
                return "Publication open failed: \(inner.localizedDescription)"
            }
        }

        private static func describe(_ error: AssetRetrieveURLError) -> String {
            switch error {
            case .schemeNotSupported(let scheme):
                return "scheme '\(scheme.rawValue)' not supported"
            case .formatNotSupported:
                return "format not recognized (sniffer found no specifications — wrong extension / corrupted file / missing file)"
            case .reading(let inner):
                return "read error: \(inner.localizedDescription)"
            }
        }
    }

    /// Runs in parallel with publication-loading. Network-bound, so the reader
    /// is already on screen by the time this returns. Late-arriving prompts /
    /// silent jumps are suppressed once `userHasNavigated` is true so they
    /// can't yank a user mid-read.
    private func promptTitle(for info: PromptInfo) -> String {
        if let title = chapterTitle(forHref: info.serverHref) {
            return "Another device is in '\(title)' — switch?"
        }
        return "Continue from another device?"
    }

    private func parseHref(_ json: String?) -> String? {
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict["href"] as? String
    }

    /// Decodes a Readium locator JSON string via the modern `JSONValue` →
    /// `Locator(json:)` path. Used wherever we have a stored or pushed
    /// locator JSON string and need a `Locator` instance.
    private func parseLocator(_ json: String?) -> Locator? {
        guard let json,
              let jsonValue = try? JSONValue(jsonString: json),
              let locator = try? Locator(json: jsonValue, warnings: nil)
        else { return nil }
        return locator
    }

    private func resolveOpen() async {
        guard let book, let sync = env.sync else { return }
        do {
            switch try await sync.onOpen(book: book) {
            case .useLocal:
                break
            case .applyServer(let progress):
                guard !userHasNavigated,
                      let locator = parseLocator(progress.locatorJSON) else { return }
                pendingJump = locator
            case .promptUser(let local, let server):
                guard !userHasNavigated else { return }
                pendingPrompt = PromptInfo(
                    local: local,
                    server: server,
                    serverHref: parseHref(server.locatorJSON)
                )
            }
        } catch {
            // Best-effort; ignore failures.
        }
    }

    private func currentBook() -> Book? {
        let id = bookID
        return try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        ).first
    }

    private func flush() async {
        guard let sync = env.sync, let book = currentBook() else { return }
        await sync.flushPendingProgress(for: book)
    }

    /// "Last read 5 min ago on '<device>'" when the server timestamp is real,
    /// or "Last read on '<device>'" when the backend handed us `.distantPast`
    /// (the sentinel for "we don't know when"). Percent isn't shown — Kobo and
    /// Readium compute whole-book progress differently, so the number wouldn't
    /// match the in-app progress bar after navigating.
    private func relativeReadMessage(for progress: CanonicalProgress) -> String {
        let device = "'\(progress.deviceName)'"
        guard progress.timestamp > .distantPast else { return "Last read on \(device)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: progress.timestamp, relativeTo: .now)
        return "Last read \(when) on \(device)"
    }

    private func pushLocator(bookID: UUID, locator: Locator) async {
        if !initialEmissionSeen {
            initialEmissionSeen = true
            return
        }
        userHasNavigated = true
        guard let book = currentBook() else { return }
        let total = locator.locations.totalProgression ?? 0
        guard let json = try? locator.jsonString() else { return }
        env.sync?.bufferLocator(
            book: book, locatorJSON: json, percentage: total
        )
    }
}
