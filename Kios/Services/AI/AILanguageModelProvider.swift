// Kios/Services/AI/AILanguageModelProvider.swift
import Foundation
import Core

final class AILanguageModelProvider: AILanguageModelProviding, @unchecked Sendable {
    private let assetStore: ModelAssetStore
    private let runtime: ModelRuntime

    init(assetStore: ModelAssetStore, runtime: ModelRuntime) {
        self.assetStore = assetStore
        self.runtime = runtime
    }

    func languageModel(for engine: AIEngine) async throws -> any LanguageModel {
        switch engine {
        case .foundationModels:
            if #available(iOS 26, *) {
                #if canImport(FoundationModels)
                return FoundationModelsLanguageModel()
                #else
                throw ProviderError.fmUnavailable
                #endif
            } else {
                throw ProviderError.fmUnavailable
            }
        case .gemma3_4b:
            let asset = ModelCatalog.gemma3_4b
            guard case .installed = assetStore.installationStatus(for: asset) else {
                throw ProviderError.gemmaNotInstalled
            }
            let runner = try await runtime.acquire(at: assetStore.directory(for: asset))
            return MLXGemmaLanguageModel(runner: runner)
        }
    }

    enum ProviderError: LocalizedError {
        case fmUnavailable
        case gemmaNotInstalled
        var errorDescription: String? {
            switch self {
            case .fmUnavailable: return "Apple Intelligence is unavailable."
            case .gemmaNotInstalled: return "Gemma model is not installed."
            }
        }
    }
}
