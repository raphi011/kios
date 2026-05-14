// Kios/Views/Settings/ModelDownloadCell.swift
import SwiftUI

struct ModelDownloadCell: View {
    let asset: ModelAsset
    let status: InstallationStatus
    let progress: DownloadProgress?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = progress {
                downloadingBody(p)
            } else {
                switch status {
                case .installed: installedBody
                case .corrupt: corruptBody
                case .notInstalled, .partial: notInstalledBody
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var notInstalledBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Download model (\(byteString(asset.totalBytes)))", systemImage: "arrow.down.circle")
            Text("Required to use the Bigger context engine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Download", action: onDownload)
                .buttonStyle(.borderedProminent)
        }
    }

    private func downloadingBody(_ p: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading… \(byteString(p.bytesDownloaded)) of \(byteString(p.bytesTotal))")
            ProgressView(value: p.fractionComplete)
            HStack {
                Text("\(Int(p.fractionComplete * 100))%")
                Spacer()
                Text("\(rateString(p.bytesPerSecond))")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
        }
    }

    private var installedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Installed • \(byteString(asset.totalBytes)) on disk", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Delete model", role: .destructive, action: onDelete)
        }
    }

    private var corruptBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Model files are corrupt", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Re-download", action: onDownload)
                .buttonStyle(.borderedProminent)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func rateString(_ bps: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bps)))/s"
    }
}
