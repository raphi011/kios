import Foundation
import SwiftUI
import SwiftData
import UIKit
import Core
import ReadiumShared

/// Composes the app's services. Created once at launch by `KiosApp`.
/// Per-source runtime services live in `sourceContexts`, built lazily via
/// `makeContext(for:)` and torn down by `removeSource`.
@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    /// Services and views share the same context so writes propagate
    /// synchronously to view fetches without crossing context boundaries.
    let modelContext: ModelContext
    let authStore: AuthStore
    /// Stateless — only depends on `modelContext`, so we construct it eagerly
    /// at init and keep it available even before credentials are present.
    let library: LibraryService

    /// Tracks reading sessions, persisted as `ReadingSession` rows.
    /// Eagerly constructed: pure-local, no credentials required.
    let stats: ReadingStatsService

    /// Imports local EPUB files. Stateless beyond `modelContext`, so we
    /// construct it eagerly at init.
    let localImporter: LocalImportService

    /// On-device AI feature switches (master toggle, preferred engine, cellular
    /// allowance). UserDefaults-backed; safe to construct eagerly.
    let aiSettings: AISettings

    /// Filesystem store for downloaded model assets (Gemma weights). Pure-local,
    /// no credentials required.
    let aiAssetStore: ModelAssetStore

    /// Background-session model downloader. Built once at boot so a single
    /// `URLSession` identifier is reused across the process lifetime.
    let aiDownloadService: ModelDownloadService

    /// Shared MLX runtime — actor-isolated, lazily loads the Gemma container
    /// on first use and evicts after the idle timeout. Built once at boot so
    /// repeated summary/ask invocations reuse the same loaded weights.
    let aiModelRuntime: ModelRuntime

    /// Shared language-model provider. Adapts `aiAssetStore` + `aiModelRuntime`
    /// (and on iOS 26+, FoundationModels) into the protocol the reader's AI
    /// services depend on.
    let aiModelProvider: AILanguageModelProvider

    /// Runtime contexts, keyed by `Source.id` (UUID). Built lazily by
    /// `makeContext(for:)`; tear-down via `tearDown(sourceID:)` /
    /// `removeSource(id:)`. The `local` source is materialised eagerly in
    /// `init` so it's always present.
    private(set) var sourceContexts: [UUID: SourceContext] = [:]

    /// The Local source singleton. Seeded on first launch by
    /// `seedLocalSourceIfNeeded()`. Force-unwrapped because the seed runs
    /// before any caller can observe `self`.
    private(set) var localSource: Source!

    // TODO: Task 14/19 — remove transitional shim
    /// TRANSITIONAL: returns the first non-local source's sync. Removed when
    /// Task 14 routes ReaderView through `context(for: book.source.id)`.
    var sync: SyncService? {
        sourceContexts.values.first(where: { $0.sync != nil })?.sync
    }

    // TODO: Task 14/19 — remove transitional shim
    /// TRANSITIONAL: returns the first non-local source's downloads. Removed
    /// when Task 14 routes DownloadingView through
    /// `context(for: book.source.id)`.
    var downloads: DownloadService? {
        sourceContexts.values.first(where: { $0.downloads != nil })?.downloads
    }

    /// Set when a reader is open. Drives the app-wide `.fullScreenCover` in
    /// `RootView`. Hoisted above `TabView` so both Home and Browse can present
    /// without double-stacking modals.
    var activeReader: ReaderRoute?

    /// Exposed (not `private`) so views can build backends for one-off
    /// operations like the Settings library refresh after a protocol switch.
    let deviceID: String

    /// Shared across `SyncService` rebuilds (e.g. on credential save) so the
    /// per-chapter koboSpan cache survives — chapters don't change without a
    /// fresh download.
    private let spanResolver = KEPUBSpanResolver()

    init() throws {
        self.modelContainer = try ModelContainer.kios()
        // Use the container's mainContext (the same one `.modelContainer(...)`
        // wires `@Query` to in views). Constructing a parallel `ModelContext`
        // here would create a second cache on the same store — service writes
        // and @Query reads would land in different in-memory snapshots, and
        // the mainContext's autosave can overwrite service writes with its
        // stale view of the same row.
        self.modelContext = self.modelContainer.mainContext
        ModelContainerFactory.applyWatermarkModelWipeIfNeeded(context: self.modelContext)
        Self.clearLanguagePreferenceIfNeeded()
        self.authStore = AuthStore()
        self.library = LibraryService(context: self.modelContext)
        self.stats = ReadingStatsService(context: self.modelContext)
        self.localImporter = LocalImportService(context: self.modelContext)

        // AI services — all pure-local, no credentials required. Constructed
        // eagerly so SettingsView (and later the reader's summary/ask sheets)
        // can read live state without nil-checks.
        self.aiSettings = AISettings()
        self.aiAssetStore = ModelAssetStore(rootDirectory: AppPaths.aiModelsDirectory)
        // Drop any on-disk model directory that isn't in the current catalog.
        // Triggers on every launch — cheap (one directory listing) and makes
        // asset-ID renames clean up after themselves automatically.
        try? self.aiAssetStore.cleanupOrphanDirectories(
            keepingAssetIDs: ModelCatalog.allKnownAssetIDs
        )
        // Background-capable URLSession config: survives app suspension during
        // the multi-GB Gemma download. Identifier is stable across launches so
        // iOS can resume any in-flight tasks after a kill + relaunch.
        let aiDlConfig = URLSessionConfiguration.background(withIdentifier: "com.raphi011.kios.aimodel.download")
        self.aiDownloadService = ModelDownloadService(
            assetStore: self.aiAssetStore,
            configuration: aiDlConfig
        )
        #if canImport(MLXLLM)
        self.aiModelRuntime = ModelRuntime(loader: MLXRunnerLoader())
        #else
        self.aiModelRuntime = ModelRuntime(loader: UnavailableRunnerLoader())
        #endif
        self.aiModelProvider = AILanguageModelProvider(
            assetStore: self.aiAssetStore,
            runtime: self.aiModelRuntime
        )

        // Subscribe to MetricKit so jetsam OOM kills (which write no .ips
        // file and never appear in Xcode Organizer's Crashes tab) and real
        // crash payloads are persisted under Application Support/kios/
        // diagnostics/ for offline retrieval via `Xcode → Devices → Download
        // Container`. Registration happens on every launch — MetricKit does
        // not buffer payloads while we're unsubscribed.
        AICrashDiagnosticsLogger.shared.install()

        // Release the heavy MLX model on memory pressure or backgrounding.
        // The container holds ~5 GB of Metal-resident weights + KV cache;
        // dropping it on pressure prevents jetsam from killing the whole
        // process for a transient spike, and backgrounding the app while
        // the model is resident is a near-guaranteed jetsam on return.
        let runtime = self.aiModelRuntime
        for name in [
            UIApplication.didReceiveMemoryWarningNotification,
            UIApplication.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { await runtime.release() }
            }
        }

        // Touch the books directory so it's created before any download runs.
        _ = AppPaths.booksDirectory

        // Stable per-install device ID, persisted to the Keychain.
        // Keychain items survive app reinstall on the same device (unlike
        // UserDefaults, which is wiped on reinstall). This matters for kosync:
        // progress records are keyed by deviceID, and keeping it stable across
        // reinstalls prevents the "is this server progress from us?" check from
        // wrongly treating our own previous progress as foreign.
        let deviceIDKeychain = KeychainStore(service: "com.raphi011.kios.deviceID")
        let deviceIDAccount = "device"
        if let existing = try? deviceIDKeychain.get(account: deviceIDAccount) {
            self.deviceID = existing
        } else {
            let generated = UUID().uuidString
            try deviceIDKeychain.set(generated, account: deviceIDAccount)
            self.deviceID = generated
        }

        // Seed the Local Source singleton before anything that depends on
        // having a Source row (sample import, eager Local context, etc.).
        seedLocalSourceIfNeeded()
        // Eagerly materialise Local — has no credentials and no network.
        _ = try? self.makeContext(for: self.localSource)

        recoverInterruptedAnalyses()
    }

    /// Inserts the Local Source row on first launch and assigns
    /// `self.localSource`. On subsequent launches, reuses the existing row.
    private func seedLocalSourceIfNeeded() {
        // Predicate-on-enum-rawValue trips the SwiftData macro in some
        // configurations; fetch all + filter is the portable fallback.
        let all = (try? modelContext.fetch(FetchDescriptor<Source>())) ?? []
        if let existing = all.first(where: { $0.kind == .local }) {
            self.localSource = existing
            return
        }
        let local = Source(
            displayName: NSLocalizedString(
                "source.local.displayName",
                value: "Local",
                comment: "Local source name"
            ),
            kind: .local,
            serverURL: nil,
            sortOrder: .max
        )
        modelContext.insert(local)
        try? modelContext.save()
        self.localSource = local
    }

    /// Marks any `BookAnalysis` rows left in `"in_progress"` from a prior
    /// launch as `"failed"` with `failureReason = "Interrupted"`. The analyze
    /// pipeline can be killed mid-flight (MLX/Metal completion fault, jetsam,
    /// force-quit) without its `catch` block running, leaving rows stuck on a
    /// status the in-process cancel button can't clear because the original
    /// `Task` no longer exists. Runs once at startup so the failed state is
    /// visible before any sheet is opened.
    private func recoverInterruptedAnalyses() {
        let descriptor = FetchDescriptor<BookAnalysis>(
            predicate: #Predicate { $0.status == "in_progress" }
        )
        guard let rows = try? modelContext.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows {
            row.status = "failed"
            row.failureReason = "Interrupted"
        }
        try? modelContext.save()
    }

    /// Returns an already-materialised context, or nil.
    func context(for sourceID: UUID) -> SourceContext? {
        sourceContexts[sourceID]
    }

    /// Lazily builds the runtime context for a source. Idempotent.
    /// Synchronous — probe runs only in `addSource`.
    @discardableResult
    func makeContext(for source: Source) throws -> SourceContext {
        if let cached = sourceContexts[source.id] { return cached }
        let (syncBackend, catalog) = try BackendFactory.build(
            source: source,
            auth: authStore,
            deviceID: deviceID,
            deviceName: UIDevice.current.name
        )
        let sync = syncBackend.map { backend in
            SyncService(
                backend: backend,
                context: modelContext,
                deviceID: deviceID,
                deviceName: UIDevice.current.name,
                spanResolver: spanResolver
            )
        }
        let downloads: DownloadService? = {
            switch source.kind {
            case .local:
                return nil
            case .opdsReadOnly:
                return DownloadService(context: modelContext, credentials: nil)
            case .kosync:
                let creds = try? authStore.load(sourceID: source.id)
                return DownloadService(
                    context: modelContext, credentials: creds?.basic
                )
            case .kobo:
                // Kobo serves pre-signed CDN URLs — no auth header.
                return DownloadService(context: modelContext, credentials: nil)
            }
        }()
        let ctx = SourceContext(
            source: source,
            sync: sync,
            downloads: downloads,
            catalog: catalog
        )
        sourceContexts[source.id] = ctx
        return ctx
    }

    /// Releases a source's runtime context. Does not delete the SwiftData row.
    func tearDown(sourceID: UUID) {
        sourceContexts.removeValue(forKey: sourceID)
        // SyncService / DownloadService don't currently have explicit cancel
        // hooks; references drop here, in-flight tasks complete naturally.
    }

    /// Probe + persist + initial refresh. Throws on probe failure with no
    /// SwiftData/Keychain trace. Step-6 failure marks `needsAttention`.
    @discardableResult
    func addSource(
        displayName: String,
        kind: SourceKind,
        serverURL: URL?,
        kosyncCredentials: ServerCredentials? = nil,
        koboCredentials: KoboCredentials? = nil
    ) async throws -> Source {
        // Build a transient Source value (NOT inserted yet) with a fresh UUID.
        let transient = Source(
            displayName: displayName,
            kind: kind,
            serverURL: serverURL,
            sortOrder: nextSortOrder()
        )
        // Probe via TransientAuthStore — fails fast without persistence.
        let probeAuth = TransientAuthStore(
            sourceID: transient.id,
            kosync: kosyncCredentials,
            kobo: koboCredentials
        )
        let (_, catalog) = try BackendFactory.build(
            source: transient,
            auth: probeAuth,
            deviceID: deviceID,
            deviceName: UIDevice.current.name
        )
        try await catalog.probe()

        // Insert SwiftData row.
        modelContext.insert(transient)
        try modelContext.save()

        // Persist credentials under the now-persisted source ID.
        if let kosync = kosyncCredentials {
            try authStore.save(sourceID: transient.id, credentials: kosync)
        }
        if let kobo = koboCredentials {
            try authStore.save(sourceID: transient.id, kobo: kobo)
        }

        // Build context + initial refresh. Failure here is non-fatal —
        // flag needsAttention so Settings can surface it.
        do {
            let ctx = try makeContext(for: transient)
            try await library.refresh(using: ctx.catalog, source: transient)
        } catch {
            transient.needsAttention = true
            try? modelContext.save()
        }
        return transient
    }

    /// Removes a source: tears down its context, purges Keychain entries,
    /// and deletes the SwiftData row (cascades into its books). Falls back
    /// `library.selectedSourceID` to another source when the removed source
    /// was the selected one. Refuses to delete the Local singleton.
    func removeSource(id: UUID) async throws {
        guard let source = try modelContext.fetch(
            FetchDescriptor<Source>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        guard source.kind != .local else {
            assertionFailure("Local source cannot be deleted")
            return
        }
        tearDown(sourceID: id)
        try authStore.purge(sourceID: id)
        modelContext.delete(source)
        try modelContext.save()

        // Fall back if this was the selected source.
        let key = "library.selectedSourceID"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: key) == id.uuidString {
            let remaining = try modelContext.fetch(
                FetchDescriptor<Source>(sortBy: [SortDescriptor(\.sortOrder)])
            )
            let fallback = remaining.first(where: { $0.kind != .local })
                ?? remaining.first(where: { $0.kind == .local })
            defaults.set(fallback?.id.uuidString, forKey: key)
        }
    }

    /// Computes the next sortOrder for a new server source. Server sources
    /// occupy [0…N); Local stays pinned at `.max`. New sources go after the
    /// highest existing server source.
    private func nextSortOrder() -> Int {
        let fetch = FetchDescriptor<Source>(
            sortBy: [SortDescriptor(\Source.sortOrder, order: .reverse)]
        )
        let all = (try? modelContext.fetch(fetch)) ?? []
        let highest = all.first(where: { $0.kind != .local })?.sortOrder
        return (highest ?? -1) + 1
    }

    /// TRANSITIONAL: legacy sign-out kept as a no-op so SettingsView still
    /// compiles. Multi-source replaces this with per-source `removeSource`.
    /// Task 18 removes this call site entirely.
    func signOut() async {
        // No-op. Per-source removal is the new flow.
    }

    /// Opens the reader for `bookID`. No-op when a reader is already open.
    func openReader(_ bookID: UUID) {
        guard activeReader == nil else { return }
        activeReader = ReaderRoute(id: bookID)
    }

    /// On first launch, import any bundled Gutenberg sample EPUBs into the
    /// library so the user has something to read before configuring a sync
    /// backend. Idempotent — gated by a UserDefaults flag so the seed runs
    /// at most once per fresh install. If the user later deletes the
    /// seeded books, they do not return: we record "we tried" rather than
    /// "the books are present."
    func seedSampleBooksIfNeeded() async {
        let key = "kios.hasSeededSampleBooks"
        if UserDefaults.standard.bool(forKey: key) { return }

        let bundle = Bundle.main
        let candidates = ["moby-dick", "frankenstein"]
        for name in candidates {
            let url = bundle.url(forResource: name, withExtension: "epub")
                ?? bundle.url(forResource: name, withExtension: "epub", subdirectory: "SampleBooks")
            guard let url else { continue }
            _ = try? await localImporter.import(from: url, localSource: self.localSource)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Pull-to-refresh for one source's catalog. Reconciles with the local
    /// Book store. Throws if credentials/network fails. Called by
    /// LibraryRootView's pull-to-refresh and by SettingsView after a save.
    func refreshLibrary(source: Source) async throws {
        let ctx = try makeContext(for: source)
        try await library.refresh(using: ctx.catalog, source: source)
    }

    /// Refreshes `book.acquisitionURL` via the source's catalog backend.
    /// For Kobo, the listLibrary response embeds pre-signed CDN URLs that
    /// expire in minutes — re-resolving the entry returns a fresh URL.
    /// Silently no-ops on failure so the caller's download attempt can still
    /// proceed with the stale URL and surface a real download error rather
    /// than blocking on the refresh.
    func refreshAcquisitionURL(for book: Book) async {
        guard book.source.kind != .local,
              let serverID = book.serverID,
              let currentURL = book.acquisitionURL else {
            return
        }
        do {
            let ctx = try makeContext(for: book.source)
            let entry = CatalogEntry(
                serverID: serverID,
                title: book.title,
                authors: book.authors,
                identity: book.identity,
                downloadURL: currentURL,
                format: book.format,
                thumbnailURL: book.thumbnailURL
            )
            let fresh = try await ctx.catalog.resolveDownload(for: entry)
            book.acquisitionURL = fresh
            try? modelContext.save()
        } catch {
            // Stale URL — let the download attempt anyway.
        }
    }

    /// Builds a `BookAnalysisService` bound to the given Readium `publication`.
    ///
    /// Each open reader session needs its own analysis service: the extractor
    /// and chapter list are derived from the per-reader `Publication`, which
    /// isn't shared across books. Callers (today: `ReaderView` via Task 22)
    /// hold one `Publication` reference for the book they're rendering and
    /// pass it in here.
    ///
    /// `Publication` is not `Sendable`, so we pre-resolve the chapter refs
    /// outside the `@Sendable` closure (the `[ChapterRef]` array is a value
    /// type and copies cleanly). The extractor wraps the `Publication` with
    /// its own `@unchecked Sendable` shield.
    func makeBookAnalysisService(publication: Publication) -> BookAnalysisService {
        let extractor = PublicationChapterTextExtractor(publication: publication)
        let chapterRefs: [ChapterRef] = publication.readingOrder.enumerated().map { idx, link in
            ChapterRef(index: idx, href: link.href, title: link.title ?? "")
        }
        let summaryHelper = AISummaryService(
            modelContext: modelContext,
            modelProvider: aiModelProvider,
            textExtractor: extractor
        )
        return BookAnalysisService(
            modelContext: modelContext,
            provider: aiModelProvider,
            extractor: extractor,
            summaryHelper: summaryHelper,
            chaptersFor: { _ in chapterRefs }
        )
    }

    /// First-launch-of-multi-source-build cleanup. Drops the SwiftData store
    /// and every Keychain entry under the legacy single-slot keys + any
    /// per-source keys from a partial install. Runs once, gated by a
    /// UserDefaults sentinel. Must run BEFORE `ModelContainer.kios()` opens
    /// the store — deleting the file under an open container is racy.
    static func applyMultiSourceWipeIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        let sentinelKey = "kios.multiSource.wipeApplied.v1"
        guard !defaults.bool(forKey: sentinelKey) else { return }

        // 1. Drop SwiftData store files (main + WAL + SHM).
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        if let support {
            let base = support.appendingPathComponent("default.store")
            let fm = FileManager.default
            try? fm.removeItem(at: base)
            try? fm.removeItem(at: support.appendingPathComponent("default.store-wal"))
            try? fm.removeItem(at: support.appendingPathComponent("default.store-shm"))
        }

        // 2. Purge the credentials Keychain service. Catches legacy single-slot
        //    entries AND any per-source entries from a partial install attempt.
        let keychain = KeychainStore(service: "com.raphi011.kios.credentials")
        try? keychain.deleteAll()

        // 3. Clear legacy single-source UserDefaults keys + the source picker
        //    selection (in case a previous build was already in this branch).
        for legacyKey in [
            "Kios.serverURL", "Kios.username", "Kios.activeProtocol",
            "Kios.koboImageURLTemplate",
            "library.selectedSourceID"
        ] {
            defaults.removeObject(forKey: legacyKey)
        }

        defaults.set(true, forKey: sentinelKey)
    }

    /// One-shot revert to system language. Drops any persisted
    /// `AppleLanguages` override (was written by the now-removed
    /// LanguagePicker) plus the stored picker selection. iOS reads
    /// `AppleLanguages` at process start, so the clear only takes effect
    /// on the NEXT launch — same constraint the picker had. Idempotent
    /// via the per-install flag; bumping the suffix re-runs the wipe.
    private static func clearLanguagePreferenceIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        let flagKey = "kios.languagePickerRemoved.v1"
        guard !defaults.bool(forKey: flagKey) else { return }
        defaults.removeObject(forKey: "AppleLanguages")
        defaults.removeObject(forKey: "kios.languagePreference")
        defaults.set(true, forKey: flagKey)
    }
}

/// Wraps just-in-time credentials so `BackendFactory.build` can probe a
/// not-yet-persisted source. Conforms to `AuthReading`.
private struct TransientAuthStore: AuthReading {
    let sourceID: UUID
    let kosync: ServerCredentials?
    let kobo: KoboCredentials?
    let oauth: OAuthCredentials?

    init(
        sourceID: UUID,
        kosync: ServerCredentials? = nil,
        kobo: KoboCredentials? = nil,
        oauth: OAuthCredentials? = nil
    ) {
        self.sourceID = sourceID
        self.kosync = kosync
        self.kobo = kobo
        self.oauth = oauth
    }

    func load(sourceID: UUID) throws -> ServerCredentials? {
        precondition(sourceID == self.sourceID)
        return kosync
    }

    func loadKobo(sourceID: UUID) throws -> KoboCredentials? {
        precondition(sourceID == self.sourceID)
        return kobo
    }

    func loadOAuth(sourceID: UUID) throws -> OAuthCredentials? {
        precondition(sourceID == self.sourceID)
        return oauth
    }
}
