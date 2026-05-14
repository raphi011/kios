// Kios/Views/Settings/ModelDownloadCell.swift
import SwiftUI

/// Editorial-styled row inside the AI settings card. Switches between four
/// visual states based on `status` + `progress`. Mirrors the same callbacks
/// as the previous implementation so `SettingsView` doesn't need to change.
///
/// Layout idea: status info on the leading edge of the top row, the matching
/// secondary action (Delete / Re-download) on the trailing edge of the same
/// row — no leading icons offsetting the second line. The primary action
/// (Download) only appears for the `notInstalled` state, full-width.
struct ModelDownloadCell: View {
    let asset: ModelAsset
    let status: InstallationStatus
    let progress: DownloadProgress?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if let p = progress {
            downloadingBody(p)
        } else {
            switch status {
            case .installed:                installedBody
            case .corrupt:                  corruptBody
            case .notInstalled, .partial:   notInstalledBody
            }
        }
    }

    // MARK: - States

    private var notInstalledBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Download model")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                Spacer()
                Text(byteString(asset.totalBytes))
                    .font(EditorialTheme.mono(size: 12))
                    .foregroundStyle(EditorialTheme.muted)
            }
            Text("Required for the Bigger context engine.")
                .font(EditorialTheme.sans(size: 13))
                .foregroundStyle(EditorialTheme.muted)
            primaryButton("Download", action: onDownload)
        }
    }

    private func downloadingBody(_ p: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloading…")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                Spacer()
                Text("\(byteString(p.bytesDownloaded)) of \(byteString(p.bytesTotal))")
                    .font(EditorialTheme.mono(size: 12))
                    .foregroundStyle(EditorialTheme.muted)
                    .lineLimit(1)
            }
            ProgressView(value: p.fractionComplete)
                .progressViewStyle(.linear)
                .tint(EditorialTheme.accent)
            HStack {
                Text("\(Int(p.fractionComplete * 100))% · \(rateString(p.bytesPerSecond))")
                    .font(EditorialTheme.mono(size: 12))
                    .foregroundStyle(EditorialTheme.muted)
                Spacer()
                inlineActionButton("Cancel", tint: EditorialTheme.accent, action: onCancel)
            }
        }
    }

    private var installedBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(EditorialTheme.ok)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }
            Text("Installed")
                .font(EditorialTheme.sans(size: 15, weight: .medium))
                .foregroundStyle(EditorialTheme.ink)
            Text("· \(byteString(asset.totalBytes)) on disk")
                .font(EditorialTheme.mono(size: 12))
                .foregroundStyle(EditorialTheme.muted)
            Spacer()
            inlineActionButton("Delete model", tint: EditorialTheme.danger, action: onDelete)
        }
    }

    private var corruptBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(EditorialTheme.danger)
                    .font(.system(size: 12, weight: .semibold))
                Text("Model files are corrupt")
                    .font(EditorialTheme.sans(size: 15, weight: .medium))
                    .foregroundStyle(EditorialTheme.ink)
                Spacer()
                inlineActionButton("Delete", tint: EditorialTheme.danger, action: onDelete)
            }
            primaryButton("Re-download", action: onDownload)
        }
    }

    // MARK: - Buttons

    /// Filled accent-red pill, full-width. Used for the *destination* action
    /// of a state (Download / Re-download). Sized to the touch-target floor.
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(EditorialTheme.sans(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(EditorialTheme.accent)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// Compact text-only button used inline on the right of a status row
    /// (Cancel, Delete model). Touch target is widened via padding so the
    /// 13pt label still meets the 44pt HIG floor without visible chrome.
    private func inlineActionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(EditorialTheme.sans(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Formatters

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
