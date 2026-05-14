// Kios/Services/AI/AIEngine.swift
import Foundation

enum AIEngine: String, Sendable, Codable, CaseIterable, Identifiable {
    case foundationModels
    case gemma4_e4b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .foundationModels: return "Built-in"
        case .gemma4_e4b:       return "Bigger context"
        }
    }
}
