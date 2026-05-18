import Foundation
import os
import SwiftUI
import SwiftData
import UIKit
import Core
import ReadiumShared

/// Composes the app's services. Created once at launch by `KiosApp`.
/// Per-source runtime contexts live on `sources`; reader presentation lives
/// on `router`. This env is the composition root + workflows that span both.
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

    /// Per-source runtime context lifecycle (sync, downloads, catalog).
    let sources: SourceRegistry

    /// Reader presentation: `router.activeReader` drives the app-wide
    /// `.fullScreenCover` in `RootView`. Views call `router.openReader(_:)`.
    let router: ReaderRouter

    /// The Local source singleton. Seeded on first launch and reused
    /// thereafter — see `Self.loadOrSeedLocalSource(in:)`. Always present.
    let localSource: Source

    /// Exposed (not `private`) so views can build backends for one-off
    /// operations like the Settings library refresh after a protocol switch.
    let deviceID: String

    init() throws {
        self.modelContainer = try ModelContainer.kios()
        // Use the container's mainContext (the same one `.modelContainer(...)`
        // wires `@Query` to in views). Constructing a parallel `ModelContext`
        // here would create a second cache on the same store — service writes
        // and @Query reads would land in different in-memory snapshots, and
        // the mainContext's autosave can overwrite service writes with its
        // stale view of the same row.
        self.modelContext = self.modelContainer.mainContext
        Migrations.applyWatermarkModelWipeIfNeeded(context: self.modelContext)
        Migrations.clearLanguagePreferenceIfNeeded()
        self.authStore = AuthStore()
        self.library = LibraryService(context: self.modelContext)
        self.stats = ReadingStatsService(context: self.modelContext)
        self.localImporter = LocalImportService(context: self.modelContext)

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
        self.localSource = Self.loadOrSeedLocalSource(in: self.modelContext)

        // Compose registry + router. Registry holds the spanResolver so
        // per-chapter caches survive SyncService rebuilds (e.g. on credential
        // save) — chapters don't change without a fresh download.
        self.sources = SourceRegistry(
            modelContext: self.modelContext,
            authStore: self.authStore,
            deviceID: self.deviceID,
            deviceName: UIDevice.current.name,
            spanResolver: KEPUBSpanResolver()
        )
        self.router = ReaderRouter()

        // Eagerly materialise Local — has no credentials and no network.
        _ = try? self.sources.makeContext(for: self.localSource)
    }

    /// Returns the existing Local Source row, or inserts and returns a fresh
    /// one if none exists. Idempotent. Static so it can run during `init`
    /// before `self` is fully initialised.
    private static func loadOrSeedLocalSource(in context: ModelContext) -> Source {
        // Predicate-on-enum-rawValue trips the SwiftData macro in some
        // configurations; fetch all + filter is the portable fallback.
        let all = (try? context.fetch(FetchDescriptor<Source>())) ?? []
        if let existing = all.first(where: { $0.kind == .local }) {
            return existing
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
        context.insert(local)
        try? context.save()
        return local
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
            let ctx = try sources.makeContext(for: transient)
            try await library.refresh(using: ctx.catalog, source: transient)
        } catch {
            Logger.app.error(
                "initial refresh failed for new source \(transient.id, privacy: .public) (\(String(describing: kind), privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
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
        sources.tearDown(sourceID: id)
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
        let ctx = try sources.makeContext(for: source)
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
            let ctx = try sources.makeContext(for: book.source)
            let entry = CatalogEntry(
                serverID: serverID,
                title: book.title,
                authors: book.authors,
                identity: book.identity,
                downloadURL: currentURL,
                format: book.format,
                thumbnailURL: book.thumbnailURL
            )
            // `nil` from the backend means "no refresh available" (e.g. a
            // local catalog) — preserve the existing URL rather than nil it.
            if let fresh = try await ctx.catalog.resolveDownload(for: entry) {
                book.acquisitionURL = fresh
                try? modelContext.save()
            }
        } catch {
            Logger.catalog.notice(
                "refreshAcquisitionURL failed for book \(book.id, privacy: .public): \(error.localizedDescription, privacy: .public) — using stale URL"
            )
            // Stale URL — let the download attempt anyway.
        }
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
