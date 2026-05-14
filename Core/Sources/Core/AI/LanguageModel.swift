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

    func extract<T: Decodable & Sendable>(
        _ type: T.Type,
        schema: String,
        system: String,
        user: String
    ) async throws -> T
}

public extension LanguageModel {
    /// Default implementation so conformers that have no extraction story yet
    /// continue to compile. Real adapters (FM via `@Generable`, Gemma via
    /// JSON-prompt + parse) override this. Mock and test doubles override too.
    func extract<T: Decodable & Sendable>(
        _ type: T.Type,
        schema: String,
        system: String,
        user: String
    ) async throws -> T {
        throw ExtractionError.unsupportedType(String(describing: type))
    }
}

public enum SummaryScope: String, Sendable, Codable, CaseIterable {
    case full
    case readSoFar
}

public enum ExtractionError: LocalizedError, Sendable {
    case unsupportedType(String)
    case malformedOutput(attempts: Int, underlying: String)
    case engineUnavailable
    case userCanceled

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "The current engine doesn't know how to extract \(name)."
        case .malformedOutput(let n, let reason):
            return "The AI engine produced invalid output after \(n) attempts: \(reason)"
        case .engineUnavailable:
            return "No AI engine is currently available. Check Settings → AI."
        case .userCanceled:
            return "Canceled."
        }
    }
}
