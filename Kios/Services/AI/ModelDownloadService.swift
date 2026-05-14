// Kios/Services/AI/ModelDownloadService.swift
import Foundation
import UIKit

protocol ModelDownloadServiceReading: Sendable {
    func currentDownload() -> DownloadProgress?
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

/// Downloads model assets to disk via per-file `URLSessionDownloadTask`s,
/// driving an internal `URLSessionDownloadDelegate` that bridges the delegate
/// callbacks to async/await via a per-file `CheckedContinuation`. Supports
/// background `URLSessionConfiguration` because we do NOT use the async
/// convenience `download(from:)` method — that one throws on background
/// configs ("Completion handler blocks are not supported in background
/// sessions"). The delegate-driven path works for any session configuration.
@MainActor
@Observable
final class ModelDownloadService: NSObject, ModelDownloadServiceReading {
    private(set) var progress: DownloadProgress?
    private(set) var lastError: ModelDownloadError?

    private let assetStore: ModelAssetStore
    private let configuration: URLSessionConfiguration

    // Per-file state. Only mutated from MainActor.
    private var activeSession: URLSession?
    private var activeContinuation: CheckedContinuation<URL, Error>?
    private var fileStartTime: Date = Date()
    private var bytesBeforeCurrentFile: Int64 = 0
    private var currentAssetID: String = ""
    private var currentAssetTotal: Int64 = 0

    /// Serial delegate queue — keeps `didFinishDownloadingTo` and
    /// `didCompleteWithError` from interleaving for a single task.
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "kios.aimodel.download.delegate"
        return q
    }()

    init(assetStore: ModelAssetStore,
         configuration: URLSessionConfiguration = .default) {
        self.assetStore = assetStore
        self.configuration = configuration
        super.init()
    }

    nonisolated func currentDownload() -> DownloadProgress? {
        MainActor.assumeIsolated { progress }
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
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        activeSession = session
        defer {
            session.finishTasksAndInvalidate()
            activeSession = nil
        }

        progress = DownloadProgress(
            assetID: asset.id,
            bytesDownloaded: 0,
            bytesTotal: asset.totalBytes,
            bytesPerSecond: 0
        )

        currentAssetID = asset.id
        currentAssetTotal = asset.totalBytes
        var bytesSoFar: Int64 = 0

        for file in asset.files {
            let url = URL(string: "https://huggingface.co/\(asset.huggingFaceRepo)/resolve/\(asset.revision)/\(file.path)")!

            bytesBeforeCurrentFile = bytesSoFar
            fileStartTime = Date()

            do {
                let stableTempURL: URL = try await withCheckedThrowingContinuation { continuation in
                    self.activeContinuation = continuation
                    let task = session.downloadTask(with: url)
                    task.resume()
                }

                let dest = dir.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: stableTempURL, to: dest)

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
                progress = DownloadProgress(
                    assetID: asset.id,
                    bytesDownloaded: bytesSoFar,
                    bytesTotal: asset.totalBytes,
                    bytesPerSecond: 0
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
        activeSession?.invalidateAndCancel()
        if let cont = activeContinuation {
            activeContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        progress = nil
        lastError = .cancelled
    }

    // MARK: - Delegate-side helpers (MainActor)

    private func resumeContinuationSuccess(_ url: URL) {
        guard let cont = activeContinuation else { return }
        activeContinuation = nil
        cont.resume(returning: url)
    }

    private func resumeContinuationFailure(_ error: Error) {
        guard let cont = activeContinuation else { return }
        activeContinuation = nil
        cont.resume(throwing: error)
    }

    private func updateProgress(totalBytesWritten: Int64) {
        let elapsed = Date().timeIntervalSince(fileStartTime)
        progress = DownloadProgress(
            assetID: currentAssetID,
            bytesDownloaded: bytesBeforeCurrentFile + totalBytesWritten,
            bytesTotal: currentAssetTotal,
            bytesPerSecond: elapsed > 0 ? Double(totalBytesWritten) / elapsed : 0
        )
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // didFinishDownloadingTo fires for ANY response, including 4xx/5xx, with
        // the response body saved to a temp file. Check the status code first.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            let urlStr = downloadTask.originalRequest?.url?.absoluteString ?? "<unknown>"
            let error = NSError(
                domain: "kios.modeldownload",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for \(urlStr)"]
            )
            Task { @MainActor in self.resumeContinuationFailure(error) }
            return
        }
        // The temp file at `location` is deleted as soon as this method returns,
        // so move it to a stable path BEFORE bouncing back to MainActor.
        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kios-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            Task { @MainActor in self.resumeContinuationSuccess(stableURL) }
        } catch {
            Task { @MainActor in self.resumeContinuationFailure(error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: (any Error)?) {
        // Successful downloads route through didFinishDownloadingTo above; only
        // surface explicit transport errors here. The MainActor helpers already
        // guard against double-resume via the `activeContinuation = nil` step.
        guard let error else { return }
        Task { @MainActor in self.resumeContinuationFailure(error) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in self.updateProgress(totalBytesWritten: totalBytesWritten) }
    }
}
