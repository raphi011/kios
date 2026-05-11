import Foundation
import SwiftUI
import SwiftData
import UIKit
import Core

/// Composes the app's services. Created once at launch by `iOSReaderApp`.
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

    /// nil when credentials are absent. Re-populated by `bootIfCredentialsPresent`.
    private(set) var sync: SyncService?
    private(set) var downloads: DownloadService?
    private(set) var opds: OPDSClient?

    private let deviceID: String

    init() throws {
        self.modelContainer = try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self
        )
        self.modelContext = ModelContext(self.modelContainer)
        self.authStore = AuthStore()

        // Touch the books directory so it's created before any download runs.
        _ = AppPaths.booksDirectory

        // Stable per-install device ID, persisted to the Keychain.
        // Keychain items survive app reinstall on the same device (unlike
        // UserDefaults, which is wiped on reinstall). This matters for kosync:
        // progress records are keyed by deviceID, and keeping it stable across
        // reinstalls prevents the "is this server progress from us?" check from
        // wrongly treating our own previous progress as foreign.
        let deviceIDKeychain = KeychainStore(service: "me.iosreader.deviceID")
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
    /// after the user saves credentials in SettingsView.
    func bootIfCredentialsPresent() throws {
        guard let creds = try authStore.load() else {
            self.sync = nil
            self.opds = nil
            // Note: we do NOT nil out `downloads`. Once created, it persists
            // for the life of the process so its background URLSession isn't
            // recreated. If credentials are cleared, the session simply has
            // no in-flight work; on next save we update the credentials.
            return
        }

        let http = HTTPClient(credentials: creds.basic)
        let opds = OPDSClient(http: http)
        self.opds = opds
        let kosync = KOSyncClient(
            baseURL: creds.serverURL.appendingPathComponent("kosync"),
            http: http
        )

        self.sync = SyncService(
            kosync: kosync, context: modelContext,
            deviceID: deviceID, deviceName: UIDevice.current.name
        )

        if let existing = self.downloads {
            // Reuse the existing DownloadService so we don't re-create its
            // background URLSession — Apple throws NSGenericException if a
            // background session with the same identifier already exists.
            existing.update(credentials: creds.basic)
        } else {
            self.downloads = DownloadService(
                context: modelContext, credentials: creds.basic
            )
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
}
