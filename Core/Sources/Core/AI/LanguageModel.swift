import Foundation

/// Streaming language-model interface. Implementations live in the Kios
/// target (FoundationModelsLanguageModel, MLXGemmaLanguageModel).
public protocol LanguageModel: Sendable {
    /// Approximate context budget in characters. Heuristic for the chunker;
    /// the model itself enforces the true token limit.
    var contextBudgetCharacters: Int { get }

    /// Streams the model's response. Implementations MUST honor Task cancellation
    /// by observing the AsyncThrowingStream continuation termination.
    func complete(
        system: String,
        user: String
    ) -> AsyncThrowingStream<String, Error>
}

public enum SummaryScope: String, Sendable, Codable, CaseIterable {
    case full
    case readSoFar
}
