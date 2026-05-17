import SwiftUI
import Core

/// Kind-discriminated credential form. Hosted by `AddSourceView` (insert mode)
/// and `SourceDetailView` (edit mode). The form is bindings-only: the parent
/// owns the state and handles persistence on submit.
struct SourceCredentialForm: View {
    let kind: SourceKind
    @Binding var displayName: String
    @Binding var serverURL: String     // raw input; caller validates
    @Binding var username: String      // kosync only
    @Binding var password: String      // kosync only
    @Binding var koboSyncURL: String   // kobo only

    var body: some View {
        Group {
            Section {
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.words)
            }
            switch kind {
            case .opdsReadOnly:
                Section {
                    TextField("OPDS catalog URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            case .kosync:
                Section {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            case .kobo:
                Section {
                    TextField("Kobo sync URL", text: $koboSyncURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Paste the URL generated in CWA admin → Kobo sync. The URL embeds the auth token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .local:
                EmptyView()
            }
        }
    }
}
