// Kios/Views/Settings/AIFirstEnableSheet.swift
import SwiftUI

struct AIFirstEnableSheet: View {
    let availability: AIAvailability
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("On-device AI features")
                        .font(.title2.bold())
                    Text("Generate chapter summaries and ask about selected passages — without sending anything to a server.")
                        .foregroundStyle(.secondary)

                    if hasAnyEngine {
                        Text("Two engines are available, depending on your device:")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 12) {
                            engineBlock(
                                title: "Built-in",
                                detail: "Uses Apple Intelligence on iOS 26+. No download.",
                                disabled: availability.fm != .available
                            )
                            engineBlock(
                                title: "Bigger context",
                                detail: "Uses a 4-billion-parameter open model. One-time ~3.5 GB download. Better at long chapters.",
                                disabled: availability.gemma != .available && availability.gemma != .modelNotDownloaded
                            )
                        }
                        Text("You can switch between them anytime in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your device doesn't support on-device AI features yet. Requires iOS 26 with Apple Intelligence, or 8 GB of RAM.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it", action: onDismiss)
                }
            }
        }
    }

    private var hasAnyEngine: Bool {
        availability.fm == .available
            || availability.gemma == .available
            || availability.gemma == .modelNotDownloaded
    }

    private func engineBlock(title: String, detail: String, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }
}
