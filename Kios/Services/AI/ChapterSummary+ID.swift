import Foundation
import Core

/// Typed composite-ID helper. Lives outside `ChapterSummary.swift` so the
/// SwiftData model file can be shared with the `KiosControls` extension
/// without dragging `AIEngine` into that target.
extension ChapterSummary {
    static func makeID(bookID: UUID, chapterHref: String, engine: AIEngine) -> String {
        "\(bookID.uuidString)|\(chapterHref)|\(engine.rawValue)"
    }
}
