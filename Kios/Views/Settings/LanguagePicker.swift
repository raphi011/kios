import SwiftUI

/// Settings section that lets the user override the app's UI language.
///
/// Writes to `AppleLanguages` via `LanguagePreferenceApplier`. iOS reads
/// that key once at process start, so the change requires a relaunch —
/// we surface that with an `.alert`. The app cannot relaunch itself
/// cleanly on iOS; the user closes from the app switcher.
struct LanguagePicker: View {
    @AppStorage("kios.languagePreference")
    private var rawPreference: String = LanguagePreference.system.rawValue

    @State private var showRestartAlert = false

    private var preference: LanguagePreference {
        LanguagePreference(rawValue: rawPreference) ?? .system
    }

    var body: some View {
        EditorialList("Language") {
            Picker("App language", selection: pickerBinding) {
                Text("Follow System").tag(LanguagePreference.system)
                Text("English").tag(LanguagePreference.english)
                Text("Deutsch").tag(LanguagePreference.german)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .alert("Restart Kios to apply the new language.",
               isPresented: $showRestartAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private var pickerBinding: Binding<LanguagePreference> {
        Binding(
            get: { preference },
            set: { newValue in
                rawPreference = newValue.rawValue
                LanguagePreferenceApplier().apply(newValue)
                showRestartAlert = true
            }
        )
    }
}
