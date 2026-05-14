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
}
