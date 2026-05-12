import SwiftUI
import UIKit
import Core

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var activeProtocol: SyncProtocol = .kosync
    /// Snapshot of the persisted protocol at view-appear time. The "Test &
    /// Save" path compares against this to decide whether the action would
    /// switch protocols (and therefore require user confirmation + a library
    /// refresh).
    @State private var originalProtocol: SyncProtocol = .kosync
    @State private var pendingConfirm: Bool = false
    @State private var kosyncServerURL: String = ""
    @State private var kosyncUsername: String = ""
    @State private var kosyncPassword: String = ""
    @State private var koboBaseURL: String = ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case testing
        case ok
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Sync protocol") {
                Picker("Protocol", selection: $activeProtocol) {
                    Text("KOReader Sync").tag(SyncProtocol.kosync)
                    Text("Kobo Sync").tag(SyncProtocol.kobo)
                }
                .pickerStyle(.segmented)

                switch activeProtocol {
                case .kosync:
                    TextField("https://cwa.example.com", text: $kosyncServerURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $kosyncUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $kosyncPassword)

                case .kobo:
                    TextField("Kobo sync URL", text: $koboBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Paste the URL from CWA admin → enable Kobo sync. The URL contains your auth token; treat it as a password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(status == .testing)
            Section {
                Button("Test & Save") { handleTestAndSaveTap() }
                    .disabled(!canTestAndSave || status == .testing)
                statusView
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    Task { await env.signOut() }
                }
            }
        }
        .navigationTitle("Settings")
        .task { await loadExisting() }
        .confirmationDialog(
            "Switch to \(activeProtocol == .kosync ? "KOReader Sync" : "Kobo Sync")?",
            isPresented: $pendingConfirm,
            titleVisibility: .visible
        ) {
            Button("Switch and refresh library") {
                Task { await testAndSave() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your library will be refreshed against the new server. Books not present on the new server will be archived (not deleted). Downloaded files and reading progress are preserved.")
        }
    }

    private var protocolIsChanging: Bool {
        activeProtocol != originalProtocol
    }

    private func handleTestAndSaveTap() {
        if protocolIsChanging {
            pendingConfirm = true
        } else {
            Task { await testAndSave() }
        }
    }

    private var canTestAndSave: Bool {
        switch activeProtocol {
        case .kosync:
            return !kosyncServerURL.isEmpty && !kosyncUsername.isEmpty && !kosyncPassword.isEmpty
        case .kobo:
            return !koboBaseURL.isEmpty
        }
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
        let current = env.authStore.loadActiveProtocol()
        activeProtocol = current
        originalProtocol = current
        if let creds = try? env.authStore.load() {
            kosyncServerURL = creds.serverURL.absoluteString
            kosyncUsername = creds.basic.username
            // Don't pre-fill password — keychain access already proved we have it,
            // and pre-filling the field would suggest the password is visible.
        }
        if let kobo = try? env.authStore.loadKobo() {
            koboBaseURL = kobo.baseURL.absoluteString
        }
    }

    private func testAndSave() async {
        status = .testing
        switch activeProtocol {
        case .kosync:
            await testAndSaveKOSync()
        case .kobo:
            await testAndSaveKobo()
        }
    }

    private func testAndSaveKOSync() async {
        let trimmed = kosyncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true else {
            status = .failure("Invalid URL")
            return
        }
        let basic = BasicCredentials(username: kosyncUsername, password: kosyncPassword)
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
                serverURL: url, username: kosyncUsername, password: kosyncPassword
            )
            env.authStore.saveActiveProtocol(.kosync)
            try env.bootIfCredentialsPresent()
            // Always refresh on save (not just on protocol switch) so re-saving
            // with the same credentials still pulls server-side library
            // changes into the local store.
            try await env.refreshLibrary()
            // Sync the baseline AFTER the refresh succeeds — if refresh throws,
            // we leave `originalProtocol` as-is so the user still sees the
            // confirmation on a retry rather than silently switching.
            originalProtocol = .kosync
            status = .ok
        } catch {
            status = .failure("Failed to save: \(error.localizedDescription)")
        }
    }

    private func testAndSaveKobo() async {
        let trimmed = koboBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.hasPrefix("http") == true else {
            status = .failure("Invalid URL")
            return
        }
        let http = HTTPClient()  // Kobo auth is in the URL path, not headers
        let kc = KoboClient(baseURL: url, http: http)
        do {
            let res = try await kc.initialization()
            // res.imageURLTemplate is non-optional in the type; if the response
            // shape was bad, KoboClient would have thrown
            // BackendError.serverShapeUnexpected already.
            try env.authStore.saveKobo(
                KoboCredentials(baseURL: url, imageURLTemplate: res.imageURLTemplate)
            )
            env.authStore.saveActiveProtocol(.kobo)
            try env.bootIfCredentialsPresent()
            try await env.refreshLibrary()
            originalProtocol = .kobo
            status = .ok
        } catch HTTPError.unauthorized {
            status = .failure("Token rejected by Kobo sync. Re-generate from CWA admin.")
        } catch HTTPError.notFound {
            status = .failure("No Kobo sync endpoint at this URL. Check the path.")
        } catch {
            status = .failure("Kobo init failed: \(error.localizedDescription)")
        }
    }

}
