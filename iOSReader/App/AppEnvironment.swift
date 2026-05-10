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
    private(set) var library: LibraryService?
    private(set) var sync: SyncService?
    private(set) var downloads: DownloadService?

    private let booksDirectory: URL
    private let deviceID: String

    init() throws {
        self.modelContainer = try ModelContainer(
            for: Book.self, LibraryServer.self,
            ReadingProgress.self, Download.self
        )
        self.modelContext = ModelContext(self.modelContainer)
        self.authStore = AuthStore()

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )
        self.booksDirectory = appSupport.appendingPathComponent("ios-reader/books")

        // Stable per-install device ID, persisted to UserDefaults.
        let key = "iOSReader.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            self.deviceID = existing
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: key)
            self.deviceID = generated
        }

        try bootIfCredentialsPresent()
    }

    /// Construct (or rebuild) the credentialled services. Called on init and
    /// after the user saves credentials in SettingsView.
    func bootIfCredentialsPresent() throws {
        guard let creds = try authStore.load() else {
            self.library = nil
            self.sync = nil
            // Note: we do NOT nil out `downloads`. Once created, it persists
            // for the life of the process so its background URLSession isn't
            // recreated. If credentials are cleared, the session simply has
            // no in-flight work; on next save we update the credentials.
            return
        }

        let http = HTTPClient(credentials: creds.basic)
        let opds = OPDSClient(http: http)
        let kosync = KOSyncClient(
            baseURL: creds.serverURL.appendingPathComponent("kosync"),
            http: http
        )

        self.library = LibraryService(
            opds: opds, context: modelContext, rootURL: creds.serverURL
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
                context: modelContext, booksDirectory: booksDirectory,
                credentials: creds.basic
            )
        }
    }
}
