import Foundation
import SwiftData

enum ModelContainerFactory {
    /// UserDefaults key for the one-shot wipe applied when the new
    /// watermark-based stats model is first observed by the build.
    /// Suffix is intentional: lets us bump on future schema sweeps.
    static let watermarkWipeFlagKey = "kios.readingStats.watermarkModelWipeApplied.v1"

    /// Idempotent. Drops all `ReadingSession` rows once per device when
    /// the flag is absent. Leaves Books, ReadingProgresses, and other
    /// entities untouched. Per CLAUDE.md: we have no installed users yet,
    /// so this is the cheap window for a destructive change.
    @MainActor
    static func applyWatermarkModelWipeIfNeeded(
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: watermarkWipeFlagKey) else { return }
        try? context.delete(model: ReadingSession.self)
        try? context.save()
        defaults.set(true, forKey: watermarkWipeFlagKey)
    }
}

extension ModelContainer {
    /// The single source of truth for the Kios schema. Used by `KiosApp`
    /// at launch and by `OpenMostRecentBookIntent` when the system spawns
    /// the intent outside the app's DI graph.
    static func kios() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 Bookmark.self, Source.self
        )
    }

    /// In-memory variant for tests and previews — shares the same schema.
    static func kiosInMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 Bookmark.self, Source.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
