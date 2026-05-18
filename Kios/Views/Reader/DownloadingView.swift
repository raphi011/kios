import SwiftUI
import SwiftData

struct DownloadingView: View {
    let book: Book
    let download: Download?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 8) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if !book.authors.isEmpty {
                    Text(book.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)

            if let download, download.state == .failed {
                VStack(spacing: 12) {
                    Text(download.error ?? "Download failed")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button("Retry") {
                        Task { _ = try? await env.sources.context(for: book.source.id)?.downloads?.download(book: book) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 8) {
                    if let download, download.totalBytes > 0 {
                        ProgressView(value: Double(download.bytesReceived),
                                     total: Double(download.totalBytes))
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 32)

                        Text(progressLabel(download))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    private func progressLabel(_ download: Download) -> String {
        let received = ByteCountFormatter.string(fromByteCount: download.bytesReceived,
                                                  countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytes,
                                               countStyle: .file)
        return "\(received) of \(total)"
    }
}
