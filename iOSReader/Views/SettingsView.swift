import SwiftUI
import Core

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case testing
        case ok
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://cwa.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }
            .disabled(status == .testing)
            Section {
                Button("Test & Save") { Task { await testAndSave() } }
                    .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty
                              || status == .testing)
                statusView
            }
        }
        .navigationTitle("Settings")
        .task { await loadExisting() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle: EmptyView()
        case .testing: ProgressView("Testing…")
        case .ok: Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func loadExisting() async {
        guard let creds = try? env.authStore.load() else { return }
        serverURL = creds.serverURL.absoluteString
        username = creds.basic.username
        // Don't pre-fill password — keychain access already proved we have it,
        // and pre-filling the field would suggest the password is visible.
    }

    private func testAndSave() async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true else {
            status = .failure("Invalid URL")
            return
        }
        status = .testing
        let basic = BasicCredentials(username: username, password: password)
        let http = HTTPClient(credentials: basic)

        // Probe OPDS — Calibre-Web (and CWA) expose it at /opds/.
        do {
            _ = try await http.data(
                for: URLRequest(url: url.appendingPathComponent("opds/"))
            )
        } catch HTTPError.unauthorized {
            status = .failure("Wrong username or password.")
            return
        } catch {
            status = .failure("Cannot reach OPDS at \(url.absoluteString)opds/.")
            return
        }

        // Probe kosync — only CWA ships this.
        do {
            let kosync = KOSyncClient(
                baseURL: url.appendingPathComponent("kosync"), http: http
            )
            _ = try await kosync.authenticate()
        } catch HTTPError.notFound {
            status = .failure(
                "Server has no /kosync — iOS Reader requires Calibre-Web-Automated."
            )
            return
        } catch HTTPError.unauthorized {
            // Inconsistent: OPDS accepted but kosync rejected. Could happen
            // if the user has an OPDS-only account on CWA (rare).
            status = .failure(
                "Credentials work for OPDS but not /kosync. Check the user has kosync access."
            )
            return
        } catch {
            status = .failure("kosync auth failed: \(error.localizedDescription)")
            return
        }

        // Both probes passed — persist and rebuild env services.
        do {
            try env.authStore.save(
                serverURL: url, username: username, password: password
            )
            try env.bootIfCredentialsPresent()
            status = .ok
        } catch {
            status = .failure("Failed to save: \(error.localizedDescription)")
        }
    }
}
