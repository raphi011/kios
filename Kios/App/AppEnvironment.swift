import Foundation
import SwiftUI
import SwiftData
import UIKit
import Core

/// Composes the app's services. Created once at launch by `KiosApp`.
/// Services are nil until valid credentials are loaded; `bootIfCredentialsPresent`
/// is called from init AND from `SettingsView` after a successful save.
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

    /// nil when credentials are absent. Re-populated by `bootIfCredentialsPresent`.
    private(set) var sync: SyncService?
    private(set) var downloads: DownloadService?
    private(set) var opds: OPDSClient?

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

        try bootIfCredentialsPresent()
    }

    /// Construct (or rebuild) the credentialled services. Called on init and
    /// after the user saves credentials in SettingsView. Dispatches on the
    /// active sync protocol — kosync needs OPDS + Basic-auth downloads;
    /// kobo skips OPDS (catalog is via KoboBackend) but still needs a
    /// DownloadService — constructed with nil credentials so the per-request
    /// Authorization header is omitted (Kobo serves pre-signed CDN URLs).
    func bootIfCredentialsPresent() throws {
        let activeProtocol = authStore.loadActiveProtocol()
        let hasCredentials: Bool
        switch activeProtocol {
        case .kosync: hasCredentials = (try? authStore.load()) != nil
        case .kobo:   hasCredentials = (try? authStore.loadKobo()) != nil
        }
        guard hasCredentials else {
            self.sync = nil
            self.opds = nil
            // Note: we do NOT nil out `downloads`. Once created, it persists
            // for the life of the process so its background URLSession isn't
            // recreated. If credentials are cleared, the session simply has
            // no in-flight work; on next save we update the credentials.
            return
        }

        // Capture the authStore by reference so the closure picks up live
        // credentials at each call (e.g. a flush after the user updates
        // settings re-reads from the same AuthStore instance).
        let auth = self.authStore
        let device = self.deviceID
        let name = UIDevice.current.name
        self.sync = SyncService(
            backendForProtocol: { proto in
                try BackendFactory.buildSync(
                    auth: auth,
                    protocol: proto,
                    deviceID: device,
                    deviceName: name
                )
            },
            context: modelContext,
            activeProtocol: activeProtocol,
            deviceID: deviceID,
            deviceName: name,
            spanResolver: spanResolver
        )

        switch activeProtocol {
        case .kosync:
            // Only kosync has an OPDS catalog and Basic-auth downloads.
            // Force-unwrap is safe — `hasCredentials` guard above proved it.
            let creds = try authStore.load()!
            let http = HTTPClient(credentials: creds.basic)
            self.opds = OPDSClient(http: http)
            if let existing = self.downloads {
                // Reuse to avoid re-creating the background URLSession —
                // Apple throws NSGenericException if a session with the same
                // identifier already exists.
                existing.update(credentials: creds.basic)
            } else {
                self.downloads = DownloadService(
                    context: modelContext, credentials: creds.basic
                )
            }
        case .kobo:
            // Kobo catalog is served by KoboBackend (acquired via SyncService's
            // backend closure); no parallel OPDSClient needed. Downloads run
            // through the same DownloadService — constructed with nil
            // credentials so no Authorization header is attached to the
            // pre-signed CDN URLs Kobo hands out.
            if let existing = self.downloads {
                // Reuse to avoid re-creating the background URLSession —
                // Apple throws NSGenericException if a session with the same
                // identifier already exists.
                existing.update(credentials: nil)
            } else {
                self.downloads = DownloadService(
                    context: modelContext, credentials: nil
                )
            }
            self.opds = nil
        }
    }

    /// Sign out: wipe credentials, all session caches, and catalog-only Book rows.
    /// Downloaded files + their Book rows are left on disk (re-auth re-links via serverID).
    func signOut() async {
        try? authStore.clear()
        await opds?.invalidateAll()
        Self.performSignOut(context: modelContext)
        try? bootIfCredentialsPresent()   // re-run guard, clears sync/opds
    }

    /// Synchronous half of sign-out, broken out for unit-testability. Wipes
    /// the image + URL caches and deletes catalog-only Book rows. The async
    /// `signOut()` wraps this with the keychain + OPDS-cache invalidations.
    static func performSignOut(context: ModelContext) {
        ImageMemoryCache.shared.removeAll()
        URLCache.shared.removeAllCachedResponses()

        // Delete catalog-only synced Book rows (no local file). Leave
        // `.local` books alone — they belong to the device, not the account.
        if let books = try? context.fetch(FetchDescriptor<Book>()) {
            for book in books where book.filename == nil && book.source == .synced {
                context.delete(book)
            }
        }
        try? context.save()
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
            _ = try? await localImporter.import(from: url)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Pulls a fresh catalog snapshot for the active protocol and reconciles
    /// it against the local Book store. Throws if credentials are absent or
    /// the network call fails. Used by `LibraryRootView`'s pull-to-refresh
    /// and by `SettingsView` after every successful Test & Save.
    func refreshLibrary() async throws {
        let name = UIDevice.current.name
        let (_, catalog) = try BackendFactory.build(
            auth: authStore,
            deviceID: deviceID,
            deviceName: name
        )
        try await library.refresh(
            using: catalog,
            activeProtocol: authStore.loadActiveProtocol()
        )
    }

    /// Refreshes `book.acquisitionURL` via the active protocol's catalog
    /// backend. For Kobo, the listLibrary response embeds pre-signed CDN URLs
    /// that expire in minutes — re-resolving the entry returns a fresh URL.
    /// KoboBackend's `resolveDownload` is a pass-through today; CWA-side TTL
    /// handling can swap in a fresh URL later without touching call sites.
    /// Silently no-ops on failure so the caller's download attempt can still
    /// proceed with the stale URL and surface a real download error rather
    /// than blocking on the refresh.
    func refreshAcquisitionURL(for book: Book) async {
        guard book.source == .synced,
              let serverID = book.serverID,
              let currentURL = book.acquisitionURL else {
            return
        }
        do {
            let name = UIDevice.current.name
            let (_, catalog) = try BackendFactory.build(
                auth: authStore, deviceID: deviceID, deviceName: name
            )
            let entry = CatalogEntry(
                serverID: serverID,
                title: book.title,
                authors: book.authors,
                identity: book.identity,
                downloadURL: currentURL,
                format: book.format,
                thumbnailURL: book.thumbnailURL
            )
            let fresh = try await catalog.resolveDownload(for: entry)
            book.acquisitionURL = fresh
            try? modelContext.save()
        } catch {
            // Stale URL — let the download attempt anyway.
        }
    }
}
