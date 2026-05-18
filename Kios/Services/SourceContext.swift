import Foundation
import Core

/// Per-source runtime aggregate. Built lazily by
/// `SourceRegistry.makeContext(for:)` and stored in
/// `SourceRegistry.contexts[source.id]`. Bundles the per-source
/// services so callers can route via `book.source.id` and get the right
/// backend without touching credentials or factory wiring directly.
///
/// `sync` is nil for source kinds with no sync protocol (`.local`,
/// `.opdsReadOnly`). `downloads` is nil for `.local` (the file is already
/// on disk; nothing to download).
@Observable
@MainActor
final class SourceContext {
    let source: Source
    let sync: SyncService?
    let downloads: DownloadService?
    let catalog: any CatalogBackend

    /// Last error from refresh / pull / push. Cleared on success.
    /// Drives the per-source banner + the Settings `needsAttention` dot.
    var lastError: (any Error)?

    init(
        source: Source,
        sync: SyncService?,
        downloads: DownloadService?,
        catalog: any CatalogBackend
    ) {
        self.source = source
        self.sync = sync
        self.downloads = downloads
        self.catalog = catalog
    }
}
