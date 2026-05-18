import Foundation
import os

/// Per-subsystem loggers for the Kios app. Use these everywhere instead
/// of `print` or swallowing errors — entries surface in Console.app under
/// the app's bundle ID, can be filtered by category, and persist for crash
/// triage without shipping a third-party logging library.
///
/// Defaults to `.public` only for stable identifiers (book/source IDs).
/// User-visible content (titles, paths, queries) stays `.private` so it
/// doesn't leak via system log dumps.
extension Logger {
    private static let subsystem = "com.raphi011.kios"

    /// App-lifecycle, composition root, environment.
    static let app = Logger(subsystem: subsystem, category: "app")

    /// One-shot data migrations + their gating sentinels.
    static let migrations = Logger(subsystem: subsystem, category: "migrations")

    /// `SyncService` and protocol backends (`KOSyncBackend`, `KoboBackend`).
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// `DownloadService` and background URLSession events.
    static let download = Logger(subsystem: subsystem, category: "download")

    /// `LocalImportService` and OPDS-bound import flows.
    static let importFlow = Logger(subsystem: subsystem, category: "import")

    /// `CatalogBackend` conformers (OPDS, Kobo, Local) and refresh flows.
    static let catalog = Logger(subsystem: subsystem, category: "catalog")

    /// `ReaderView`, `ReaderViewModel`, navigator host, span resolver.
    static let reader = Logger(subsystem: subsystem, category: "reader")

    /// `ReadingStatsService` and session/jump-pill bookkeeping.
    static let stats = Logger(subsystem: subsystem, category: "stats")
}
