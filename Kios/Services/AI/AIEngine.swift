// Kios/Services/AI/AIEngine.swift
import Foundation

enum AIEngine: String, Sendable, Codable, CaseIterable, Identifiable {
    case foundationModels
    case gemma3_4b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: return "Built-in"
        case .gemma3_4b:        return "Bigger context"
        }
    }

    var downloadSizeBytes: Int64? {
        switch self {
        case .foundationModels: return nil
        case .gemma3_4b:        return 2_500_000_000
        }
    }
}
