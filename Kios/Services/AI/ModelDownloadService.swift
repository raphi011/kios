// Kios/Services/AI/ModelDownloadService.swift
import Foundation
import UIKit

protocol ModelDownloadServiceReading: Sendable {
    @MainActor func currentDownload() -> DownloadProgress?
}

struct DownloadProgress: Sendable, Equatable {
    let assetID: String
    let bytesDownloaded: Int64
    let bytesTotal: Int64
    let bytesPerSecond: Double
    var fractionComplete: Double {
        guard bytesTotal > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(bytesTotal)
    }
}

enum ModelDownloadError: LocalizedError, Sendable, Equatable {
    case notEnoughStorage(needBytes: Int64, freeBytes: Int64)
    case noNetwork
    case cellularBlocked
    case integrityCheckFailed(file: String)
    case cancelled
    case transient(underlying: String)

    var errorDescription: String? {
        switch self {
        case .notEnoughStorage(let need, let free):
            return "Not enough storage. Need \(need) bytes, have \(free)."
        case .noNetwork: return "No network connection."
        case .cellularBlocked: return "Wi-Fi required for this download."
        case .integrityCheckFailed(let file): return "Downloaded file \(file) is corrupt."
        case .cancelled: return "Download cancelled."
        case .transient(let underlying): return "Download failed: \(underlying)"
        }
    }
}

@MainActor
@Observable
final class ModelDownloadService: ModelDownloadServiceReading {
    private(set) var progress: DownloadProgress?
    private(set) var lastError: ModelDownloadError?

    private let assetStore: ModelAssetStore
    private let configuration: URLSessionConfiguration
    private var currentTask: Task<Void, Never>?

    init(assetStore: ModelAssetStore,
         configuration: URLSessionConfiguration = .background(withIdentifier: "com.raphi011.kios.aimodel.download")) {
        self.assetStore = assetStore
        self.configuration = configuration
    }

    func currentDownload() -> DownloadProgress? {
        progress
    }

    func startDownload(of asset: ModelAsset, allowCellular: Bool) async {
        lastError = nil
        let free = assetStore.diskFreeBytes()
        let (need, overflowed) = asset.totalBytes.addingReportingOverflow(500_000_000)
        if overflowed || free < need {
            lastError = .notEnoughStorage(needBytes: overflowed ? Int64.max : need, freeBytes: free)
            return
        }
        let dir = assetStore.directory(for: asset)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        configuration.allowsCellularAccess = allowCellular
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        progress = DownloadProgress(
            assetID: asset.id,
            bytesDownloaded: 0,
            bytesTotal: asset.totalBytes,
            bytesPerSecond: 0
        )

        var bytesSoFar: Int64 = 0
        let start = Date()

        for file in asset.files {
            let url = URL(string: "https://huggingface.co/\(asset.huggingFaceRepo)/resolve/\(asset.revision)/\(file.path)")!
            do {
                let (tempURL, response) = try await session.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = .transient(underlying: "HTTP \(http.statusCode) for \(file.path)")
                    return
                }
                let dest = dir.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)

                let data = try Data(contentsOf: dest, options: .mappedIfSafe)
                let sha = ModelAssetStore.sha256Hex(of: data)
                if sha.lowercased() != file.sha256.lowercased() {
                    try? FileManager.default.removeItem(at: dest)
                    lastError = .integrityCheckFailed(file: file.path)
                    return
                }

                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutableDest = dest
                try? mutableDest.setResourceValues(resourceValues)

                bytesSoFar += file.sizeBytes
                let elapsed = Date().timeIntervalSince(start)
                progress = DownloadProgress(
                    assetID: asset.id,
                    bytesDownloaded: bytesSoFar,
                    bytesTotal: asset.totalBytes,
                    bytesPerSecond: elapsed > 0 ? Double(bytesSoFar) / elapsed : 0
                )
            } catch is CancellationError {
                lastError = .cancelled
                return
            } catch {
                lastError = .transient(underlying: error.localizedDescription)
                return
            }
        }
        progress = nil
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        progress = nil
        lastError = .cancelled
    }
}
