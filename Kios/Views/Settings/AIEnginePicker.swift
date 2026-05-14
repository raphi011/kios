// Kios/Views/Settings/AIEnginePicker.swift
import SwiftUI

struct AIEnginePicker: View {
    let availability: AIAvailability
    @Binding var preferredEngine: AIEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditorialSegmented(
                items: [
                    (label: "Bigger context", value: AIEngine.gemma4_e4b),
                    (label: "Built-in",       value: AIEngine.foundationModels),
                ],
                selection: $preferredEngine
            )
            .disabled(disabledMessage != nil)
            .opacity(disabledMessage == nil ? 1.0 : 0.5)

            if let msg = disabledMessage {
                Text(msg)
                    .font(EditorialTheme.sans(size: 13))
                    .foregroundStyle(EditorialTheme.muted)
            }
            if let footnote = perEngineFootnote {
                Text(footnote)
                    .font(EditorialTheme.sans(size: 13))
                    .foregroundStyle(EditorialTheme.muted)
            }
        }
    }

    private var disabledMessage: String? {
        if availability.fm == .userDisabled && availability.gemma == .userDisabled {
            return "Enable AI features to choose an engine."
        }
        return nil
    }

    /// Per-engine state hint. Intentionally omits the `modelDownloading`
    /// case — the `ModelDownloadCell` below shows the live progress bar +
    /// rate + Cancel button, so a duplicate text footnote here would just
    /// add visual noise. Same for `available`, which doesn't need a hint.
    private var perEngineFootnote: String? {
        switch preferredEngine {
        case .gemma4_e4b:
            switch availability.gemma {
            case .unsupportedDevice: return "Bigger context requires roughly 8 GB of RAM."
            case .modelNotDownloaded: return "Download the model below to use this engine."
            case .modelCorrupt: return "Model files are corrupt. Re-download below."
            case .available, .modelDownloading, .userDisabled, .unsupportedOS, .modelNotReady:
                return nil
            }
        case .foundationModels:
            switch availability.fm {
            case .unsupportedOS: return "Built-in requires iOS 26 or later."
            case .unsupportedDevice: return "Built-in requires Apple Intelligence."
            case .modelNotReady: return "Apple Intelligence isn't enabled. Open iOS Settings → Apple Intelligence & Siri."
            case .available, .userDisabled, .modelNotDownloaded, .modelDownloading, .modelCorrupt:
                return nil
            }
        }
    }
}
