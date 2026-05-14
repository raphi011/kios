// Kios/Services/AI/ModelAssetStore.swift
import Foundation
import CryptoKit

protocol ModelAssetStoreReading: Sendable {
    func installationStatus(for asset: ModelAsset) -> InstallationStatus
}

enum InstallationStatus: Sendable, Equatable {
    case notInstalled
    case partial(installedBytes: Int64)
    case installed(at: URL)
    case corrupt(reason: String)
}

final class ModelAssetStore: ModelAssetStoreReading, @unchecked Sendable {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func directory(for asset: ModelAsset) -> URL {
        rootDirectory.appendingPathComponent(asset.id, isDirectory: true)
    }

    func installationStatus(for asset: ModelAsset) -> InstallationStatus {
        let dir = directory(for: asset)
        var bytes: Int64 = 0
        var foundAny = false
        var missingAny = false
        for file in asset.files {
            let fileURL = dir.appendingPathComponent(file.path)
            guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else {
                missingAny = true
                continue
            }
            foundAny = true
            if size != file.sizeBytes {
                return .corrupt(reason: "size mismatch for \(file.path): \(size) != \(file.sizeBytes)")
            }
            bytes += size
        }
        if !foundAny { return .notInstalled }
        if missingAny { return .partial(installedBytes: bytes) }
        return .installed(at: dir)
    }

    func verifyIntegrity(of asset: ModelAsset) async throws -> Bool {
        let dir = directory(for: asset)
        for file in asset.files {
            let url = dir.appendingPathComponent(file.path)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if Self.sha256Hex(of: data).lowercased() != file.sha256.lowercased() {
                return false
            }
        }
        return true
    }

    func delete(_ asset: ModelAsset) throws {
        let dir = directory(for: asset)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    func diskFreeBytes() -> Int64 {
        guard let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return free
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
