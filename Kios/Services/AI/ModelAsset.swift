// Kios/Services/AI/ModelAsset.swift
import Foundation

struct ModelAsset: Sendable, Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let engine: AIEngine
    let huggingFaceRepo: String
    let revision: String
    let files: [AssetFile]
    let totalBytes: Int64
}

struct AssetFile: Sendable, Codable, Equatable {
    let path: String
    let sha256: String
    let sizeBytes: Int64
}
