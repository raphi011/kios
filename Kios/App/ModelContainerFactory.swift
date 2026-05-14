import Foundation
import SwiftData

extension ModelContainer {
    /// The single source of truth for the Kios schema. Used by `KiosApp`
    /// at launch and by `OpenMostRecentBookIntent` when the system spawns
    /// the intent outside the app's DI graph.
    static func kios() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 ChapterSummary.self, BookAnalysis.self, CharacterMention.self
        )
    }

    /// In-memory variant for tests and previews — shares the same schema.
    static func kiosInMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Book.self, ReadingProgress.self, Download.self, ReadingSession.self,
                 ChapterSummary.self, BookAnalysis.self, CharacterMention.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
