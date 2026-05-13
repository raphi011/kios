import Foundation
import SwiftData

/// SwiftData fetch wrapper around `StatsAggregator.continueReadingCandidate`.
/// Used by `OpenMostRecentBookIntent` so the intent shares the home hero's
/// selection rule exactly.
enum MostRecentBookSelector {
    @MainActor
    static func pick(in context: ModelContext) -> Book? {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<ReadingSession>())) ?? []
        let progresses = (try? context.fetch(FetchDescriptor<ReadingProgress>())) ?? []
        let progressByID = Dictionary(
            progresses.map { ($0.bookID, $0.percentage) },
            uniquingKeysWith: { first, _ in first }
        )
        return StatsAggregator.continueReadingCandidate(
            books: books,
            progressByBookID: progressByID,
            sessions: sessions
        )
    }
}
