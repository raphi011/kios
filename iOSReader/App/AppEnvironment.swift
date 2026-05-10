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
            self.downloads = nil
            return
        }

        let http = HTTPClient(credentials: creds.basic)
        let opds = OPDSClient(http: http)
        let kosync = KOSyncClient(
            baseURL: creds.serverURL.appendingPathComponent("kosync"),
            http: http
        )
        let context = ModelContext(modelContainer)

        let deviceName = UIDevice.current.name

        self.library = LibraryService(
            opds: opds, context: context, rootURL: creds.serverURL
        )
        self.sync = SyncService(
            kosync: kosync, context: context,
            deviceID: deviceID, deviceName: deviceName
        )
        self.downloads = DownloadService(
            context: context, booksDirectory: booksDirectory,
            credentials: creds.basic
        )
    }
}
