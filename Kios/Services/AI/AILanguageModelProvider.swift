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
        case .gemma4_e4b:
            // MLX's Metal kernels aren't supported by the iOS Simulator's Metal
            // subset; loading the model crashes the process inside
            // `mlx::core::metal::Device::Device()`. Fail fast with a clear
            // message so the summary sheet shows an error card instead.
            #if targetEnvironment(simulator)
            throw ProviderError.gemmaUnsupportedOnSimulator
            #else
            let asset = ModelCatalog.gemma4_e4b
            guard case .installed = assetStore.installationStatus(for: asset) else {
                throw ProviderError.gemmaNotInstalled
            }
            let runner = try await runtime.acquire(at: assetStore.directory(for: asset))
            return MLXGemmaLanguageModel(runner: runner)
            #endif
        }
    }

    enum ProviderError: LocalizedError {
        case fmUnavailable
        case gemmaNotInstalled
        case gemmaUnsupportedOnSimulator

        var errorDescription: String? {
            switch self {
            case .fmUnavailable:
                return "Apple Intelligence is unavailable."
            case .gemmaNotInstalled:
                return "Gemma model is not installed."
            case .gemmaUnsupportedOnSimulator:
                return "MLX-based engines (including Gemma 4 E4B) can't run in the iOS Simulator. Test on a real device, or switch to the Built-in engine in Settings."
            }
        }
    }
}
