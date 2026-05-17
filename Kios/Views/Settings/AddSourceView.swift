import SwiftUI
import Core

/// New-source form. Pushed onto Settings' nav stack from the Sources list
/// (Task 18). User picks a kind, fills the kind-specific credentials, hits
/// Save. We probe the catalog before persisting — a failed probe surfaces
/// inline and leaves no on-disk trace.
struct AddSourceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SourceKind = .kosync
    @State private var displayName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var koboSyncURL: String = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $kind) {
                    Text("KOReader sync (kosync)").tag(SourceKind.kosync)
                    Text("Kobo sync").tag(SourceKind.kobo)
                    Text("OPDS (read-only)").tag(SourceKind.opdsReadOnly)
                }
                .pickerStyle(.menu)
            }
            SourceCredentialForm(
                kind: kind,
                displayName: $displayName,
                serverURL: $serverURL,
                username: $username,
                password: $password,
                koboSyncURL: $koboSyncURL
            )
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button("Save", action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        // Auto-suggest display name from the server URL's host.
        .onChange(of: serverURL) { _, new in
            autosuggestDisplayName(from: new)
        }
        .onChange(of: koboSyncURL) { _, new in
            autosuggestDisplayName(from: new)
        }
        .onChange(of: kind) { _, _ in
            errorMessage = nil
        }
    }

    /// Per-kind minimum to enable Save. Each kind has different required
    /// fields; display name is always required.
    private var canSubmit: Bool {
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .opdsReadOnly:
            return URL(string: serverURL) != nil
        case .kosync:
            return URL(string: serverURL) != nil
                && !username.isEmpty
                && !password.isEmpty
        case .kobo:
            return KoboCredentials.parse(koboSyncURL) != nil
        case .local:
            return false  // local is the singleton; can't add another
        }
    }

    private func autosuggestDisplayName(from raw: String) {
        guard displayName.isEmpty else { return }
        guard let host = URL(string: raw)?.host else { return }
        // Drop common subdomain prefixes for a nicer default.
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // First label only: "books.example.com" → "books".
        displayName = trimmed.split(separator: ".").first.map(String.init) ?? trimmed
    }

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let parsedServerURL: URL? = {
                    switch kind {
                    case .opdsReadOnly, .kosync: return URL(string: serverURL)
                    case .kobo, .local: return nil
                    }
                }()
                let kosyncCreds: ServerCredentials? = {
                    guard kind == .kosync, let url = URL(string: serverURL) else { return nil }
                    return ServerCredentials(
                        serverURL: url,
                        basic: BasicCredentials(username: username, password: password)
                    )
                }()
                let koboCreds: KoboCredentials? = {
                    guard kind == .kobo else { return nil }
                    return KoboCredentials.parse(koboSyncURL)
                }()
                _ = try await env.addSource(
                    displayName: displayName.trimmingCharacters(in: .whitespaces),
                    kind: kind,
                    serverURL: parsedServerURL,
                    kosyncCredentials: kosyncCreds,
                    koboCredentials: koboCreds
                )
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}
