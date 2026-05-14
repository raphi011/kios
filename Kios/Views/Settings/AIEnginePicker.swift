// Kios/Views/Settings/AIEnginePicker.swift
import SwiftUI

struct AIEnginePicker: View {
    let availability: AIAvailability
    @Binding var preferredEngine: AIEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Engine", selection: $preferredEngine) {
                Text("Bigger context (recommended)").tag(AIEngine.gemma3_4b)
                Text("Built-in").tag(AIEngine.foundationModels)
            }
            .pickerStyle(.segmented)
            .disabled(disabledMessage != nil)

            if let msg = disabledMessage {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let footnote = perEngineFootnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disabledMessage: String? {
        if availability.fm == .userDisabled && availability.gemma == .userDisabled {
            return "Enable AI features to choose an engine."
        }
        return nil
    }

    private var perEngineFootnote: String? {
        switch preferredEngine {
        case .gemma3_4b:
            switch availability.gemma {
            case .unsupportedDevice: return "Bigger context requires 8 GB of RAM."
            case .modelNotDownloaded: return "Download the model below to use this engine."
            case .modelDownloading(let p): return "Downloading… \(Int(p * 100))%"
            case .modelCorrupt: return "Model files are corrupt. Re-download below."
            case .available, .userDisabled, .unsupportedOS, .modelNotReady: return nil
            }
        case .foundationModels:
            switch availability.fm {
            case .unsupportedOS: return "Built-in requires iOS 26 or later."
            case .unsupportedDevice: return "Built-in requires Apple Intelligence."
            case .modelNotReady: return "Apple Intelligence is still preparing on this device."
            case .available, .userDisabled, .modelNotDownloaded, .modelDownloading, .modelCorrupt: return nil
            }
        }
    }
}
