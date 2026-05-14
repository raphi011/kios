import Foundation
import Core

/// Typed composite-ID helper. Lives outside `ChapterSummary.swift` so the
/// SwiftData model file can be shared with the `KiosControls` extension
/// without dragging `Core.SummaryScope` and `AIEngine` into that target.
extension ChapterSummary {
    static func makeID(bookID: UUID, chapterHref: String, scope: SummaryScope, engine: AIEngine) -> String {
        "\(bookID.uuidString)|\(chapterHref)|\(scope.rawValue)|\(engine.rawValue)"
    }
}
