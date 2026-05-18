import Foundation
import SwiftData
import UIKit
import Core

/// Owns the per-source runtime contexts. Built lazily by `makeContext(for:)`,
/// torn down by `tearDown(sourceID:)`. Extracted from `AppEnvironment` so
/// source lifecycle is testable in isolation and the env stays a thin
/// composition root.
@MainActor
@Observable
final class SourceRegistry {
    private(set) var contexts: [UUID: SourceContext] = [:]

    private let modelContext: ModelContext
    private let authStore: AuthStore
    private let deviceID: String
    private let deviceName: String
    /// Shared across `SyncService` rebuilds (e.g. on credential save) so the
    /// per-chapter koboSpan cache survives — chapters don't change without a
    /// fresh download.
    private let spanResolver: KEPUBSpanResolver

    init(
        modelContext: ModelContext,
        authStore: AuthStore,
        deviceID: String,
        deviceName: String,
        spanResolver: KEPUBSpanResolver
    ) {
        self.modelContext = modelContext
        self.authStore = authStore
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.spanResolver = spanResolver
    }

    /// Returns an already-materialised context, or nil.
    func context(for sourceID: UUID) -> SourceContext? {
        contexts[sourceID]
    }

    /// Lazily builds the runtime context for a source. Idempotent.
    /// Synchronous — probe runs only in `AppEnvironment.addSource`.
    @discardableResult
    func makeContext(for source: Source) throws -> SourceContext {
        if let cached = contexts[source.id] { return cached }
        let (syncBackend, catalog) = try BackendFactory.build(
            source: source,
            auth: authStore,
            deviceID: deviceID,
            deviceName: deviceName
        )
        let sync = syncBackend.map { backend in
            SyncService(
                backend: backend,
                context: modelContext,
                deviceID: deviceID,
                deviceName: deviceName,
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
        contexts[source.id] = ctx
        return ctx
    }

    /// Releases a source's runtime context. Does not delete the SwiftData row.
    func tearDown(sourceID: UUID) {
        contexts.removeValue(forKey: sourceID)
        // SyncService / DownloadService don't currently have explicit cancel
        // hooks; references drop here, in-flight tasks complete naturally.
    }
}
