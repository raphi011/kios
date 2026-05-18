import Foundation
import SwiftData
import Core

/// One-shot data migrations. Each runs once per install, gated by a
/// UserDefaults sentinel. Per `CLAUDE.md`, the app has no shipped users
/// yet, so destructive wipes are the chosen migration tool. When the app
/// ships, replace these with SwiftData `SchemaMigrationPlan`.
///
/// All flags follow the convention `kios.<feature>.<verb>.v<n>` — bump
/// the suffix to re-run the wipe on a future build.
enum Migrations {

    // MARK: - Multi-source wipe (must run pre-init)

    /// First-launch-of-multi-source-build cleanup. Drops the SwiftData store
    /// and every Keychain entry under the legacy single-slot keys + any
    /// per-source keys from a partial install. Runs once, gated by a
    /// UserDefaults sentinel.
    ///
    /// Must run BEFORE `ModelContainer.kios()` opens the store — deleting
    /// the file under an open container is racy.
    static func applyMultiSourceWipeIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        let sentinelKey = "kios.multiSource.wipeApplied.v1"
        guard !defaults.bool(forKey: sentinelKey) else { return }

        // 1. Drop SwiftData store files (main + WAL + SHM).
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        if let support {
            let base = support.appendingPathComponent("default.store")
            let fm = FileManager.default
            try? fm.removeItem(at: base)
            try? fm.removeItem(at: support.appendingPathComponent("default.store-wal"))
            try? fm.removeItem(at: support.appendingPathComponent("default.store-shm"))
        }

        // 2. Purge the credentials Keychain service. Catches legacy single-slot
        //    entries AND any per-source entries from a partial install attempt.
        let keychain = KeychainStore(service: "com.raphi011.kios.credentials")
        try? keychain.deleteAll()

        // 3. Clear legacy single-source UserDefaults keys + the source picker
        //    selection (in case a previous build was already in this branch).
        for legacyKey in [
            "Kios.serverURL", "Kios.username", "Kios.activeProtocol",
            "Kios.koboImageURLTemplate",
            "library.selectedSourceID"
        ] {
            defaults.removeObject(forKey: legacyKey)
        }

        defaults.set(true, forKey: sentinelKey)
    }

    // MARK: - Watermark stats wipe (post-container, pre-use)

    static let watermarkWipeFlagKey = "kios.readingStats.watermarkModelWipeApplied.v1"

    /// Drops all `ReadingSession` rows once per device when the flag is
    /// absent. Leaves Books, ReadingProgresses, and other entities
    /// untouched. Per CLAUDE.md: we have no installed users yet, so this is
    /// the cheap window for a destructive change.
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

    // MARK: - Language-preference wipe

    /// One-shot revert to system language. Drops any persisted
    /// `AppleLanguages` override (was written by the now-removed
    /// LanguagePicker) plus the stored picker selection. iOS reads
    /// `AppleLanguages` at process start, so the clear only takes effect
    /// on the NEXT launch — same constraint the picker had.
    static func clearLanguagePreferenceIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        let flagKey = "kios.languagePickerRemoved.v1"
        guard !defaults.bool(forKey: flagKey) else { return }
        defaults.removeObject(forKey: "AppleLanguages")
        defaults.removeObject(forKey: "kios.languagePreference")
        defaults.set(true, forKey: flagKey)
    }
}
