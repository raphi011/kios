// Kios/Services/AI/AIAvailability.swift
import Foundation

enum EngineAvailability: Sendable, Equatable {
    case available
    case userDisabled
    case unsupportedOS
    case unsupportedDevice
    case modelNotReady
    case modelNotDownloaded
    case modelDownloading(progress: Double)
    case modelCorrupt
}

protocol FMCapabilityProbing: Sendable {
    func probe() -> EngineAvailability
}

struct StaticFMProbe: FMCapabilityProbing {
    let value: EngineAvailability
    func probe() -> EngineAvailability { value }
}

#if canImport(FoundationModels)
import FoundationModels
struct SystemFMProbe: FMCapabilityProbing {
    func probe() -> EngineAvailability {
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unsupportedDevice
            case .unavailable(.appleIntelligenceNotEnabled),
                 .unavailable(.modelNotReady):
                return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
        return .unsupportedOS
    }
}
#else
struct SystemFMProbe: FMCapabilityProbing {
    func probe() -> EngineAvailability { .unsupportedOS }
}
#endif

struct AIAvailability: Sendable, Equatable {
    let fm: EngineAvailability
    let gemma: EngineAvailability

    func resolved(preferred: AIEngine, userEnabled: Bool) -> AIEngine? {
        guard userEnabled else { return nil }
        let other: AIEngine = (preferred == .gemma3_4b) ? .foundationModels : .gemma3_4b
        if engineState(preferred) == .available { return preferred }
        if engineState(other) == .available { return other }
        return nil
    }

    private func engineState(_ engine: AIEngine) -> EngineAvailability {
        switch engine {
        case .foundationModels: return fm
        case .gemma3_4b:        return gemma
        }
    }

    static func resolve(
        userEnabled: Bool,
        preferredEngine: AIEngine,
        capability: DeviceCapability,
        assetStore: ModelAssetStoreReading,
        downloads: ModelDownloadServiceReading,
        fmProbe: FMCapabilityProbing = SystemFMProbe()
    ) -> AIAvailability {
        guard userEnabled else {
            return AIAvailability(fm: .userDisabled, gemma: .userDisabled)
        }

        let fm = fmProbe.probe()

        let gemma: EngineAvailability
        if !capability.supportsGemma3_4b {
            gemma = .unsupportedDevice
        } else if let progress = downloads.currentDownload(),
                  progress.assetID == ModelCatalog.gemma3_4b.id {
            gemma = .modelDownloading(progress: progress.fractionComplete)
        } else {
            switch assetStore.installationStatus(for: ModelCatalog.gemma3_4b) {
            case .installed: gemma = .available
            case .notInstalled, .partial: gemma = .modelNotDownloaded
            case .corrupt: gemma = .modelCorrupt
            }
        }

        return AIAvailability(fm: fm, gemma: gemma)
    }
}
