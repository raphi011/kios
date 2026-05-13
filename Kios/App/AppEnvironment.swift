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
        self.modelContainer = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self
        )
        // Use the container's mainContext (the same one `.modelContainer(...)`
        // wires `@Query` to in views). Constructing a parallel `ModelContext`
        // here would create a second cache on the same store — service writes
        // and @Query reads would land in different in-memory snapshots, and
        // the mainContext's autosave can overwrite service writes with its
        // stale view of the same row.
        self.modelContext = self.modelContainer.mainContext
        self.authStore = AuthStore()
        self.library = LibraryService(context: self.modelContext)

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

        // Delete catalog-only Book rows (no local file).
        if let books = try? context.fetch(FetchDescriptor<Book>()) {
            for book in books where book.filename == nil {
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
        do {
            let name = UIDevice.current.name
            let (_, catalog) = try BackendFactory.build(
                auth: authStore, deviceID: deviceID, deviceName: name
            )
            let entry = CatalogEntry(
                serverID: book.serverID,
                title: book.title,
                authors: book.authors,
                identity: book.identity,
                downloadURL: book.acquisitionURL,
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
