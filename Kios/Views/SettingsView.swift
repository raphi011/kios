import SwiftUI
import UniformTypeIdentifiers
import Core

/// Editorial settings screen. Matches the design package's `EditorialSettings`:
/// Reading / Library & sync / AI assistant / Account sections in grouped
/// inset cards under a big serif **Settings** title, with a version footer.
///
/// Most rows are stubs — the design calls for placeholders so the chrome lands
/// before the underlying features (themes, AI, transitions) exist. Rows that
/// work today: Import EPUB, Sync protocol/URL (push to `SyncSetupView`),
/// Signed in as, Sign out.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    // Reading — display-only stubs until the reader settings model lands.
    @State private var defaultTheme = "Paper"
    @State private var defaultFont = "Newsreader"
    @State private var pageTransition = "Slide"
    @State private var tapZones = "Edges"

    // Library & sync — toggles persist in-session only.
    @State private var syncOverCellular = false

    // AI — toggles persist in-session only. The master switch dims dependents,
    // matching the design's "Disable the master switch to make no AI calls".
    @State private var aiEnabled = true
    @State private var chapterSummaries = true
    @State private var bookSoFarSummaries = true
    @State private var vocabLookup = true
    @State private var aiModel = "Claude Haiku 4.5"

    // File importer (Import EPUB row).
    @State private var showFileImporter = false
    @State private var importError: String?

    // Sign-out confirmation.
    @State private var showSignOutConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EditorialNavBar(title: "Settings")

                readingSection
                librarySyncSection
                aiSection
                accountSection

                Text(versionLine)
                    .editorialEyebrow()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                Color.clear.frame(height: 110)   // tab-bar breathing
            }
        }
        .background(EditorialTheme.bg)
        .navigationBarHidden(true)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleImport(result) }
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog(
            "Sign out?",
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                Task { await env.signOut() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Catalog will be cleared. Downloaded books and reading progress stay on this device.")
        }
    }

    // MARK: - Reading

    private var readingSection: some View {
        EditorialList("Reading") {
            stubRow(label: "Default theme", value: defaultTheme)
            EditorialHairline()
            stubRow(label: "Default font", value: defaultFont)
            EditorialHairline()
            stubRow(label: "Page transition", value: pageTransition)
            EditorialHairline()
            stubRow(label: "Tap zones", value: tapZones)
        }
    }

    // MARK: - Library & sync

    private var librarySyncSection: some View {
        EditorialList(
            "Library & sync",
            footer: "Paste the URL from CWA admin → enable Kobo sync. The URL contains your auth token; treat it as a password."
        ) {
            Button { showFileImporter = true } label: {
                EditorialRow(
                    label: "Import EPUB",
                    detail: "From Files, iCloud, AirDrop…",
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            EditorialHairline()

            NavigationLink {
                SyncSetupView()
            } label: {
                EditorialRow(
                    label: "Sync protocol",
                    value: syncProtocolName,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            EditorialHairline()

            NavigationLink {
                SyncSetupView()
            } label: {
                EditorialRow(
                    label: "Sync URL",
                    value: syncURLMasked,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            EditorialHairline()

            // Last synced is a display-only row until the sync layer surfaces
            // a real timestamp. Showing "—" keeps the layout intact.
            EditorialRow(label: "Last synced", value: "—")
            EditorialHairline()

            EditorialRow(
                label: "Sync over cellular",
                toggle: $syncOverCellular
            )
        }
    }

    // MARK: - AI assistant

    private var aiSection: some View {
        EditorialList(
            "AI assistant",
            footer: "Summaries are generated on demand — text never leaves the chapter you ask about. Disable the master switch to make no AI calls at all."
        ) {
            EditorialRow(label: "Enable AI features", toggle: $aiEnabled)
            EditorialHairline()

            EditorialRow(label: "Chapter summaries", toggle: $chapterSummaries)
                .disabled(!aiEnabled).opacity(aiEnabled ? 1 : 0.4)
            EditorialHairline()

            EditorialRow(label: "Book-so-far summaries", toggle: $bookSoFarSummaries)
                .disabled(!aiEnabled).opacity(aiEnabled ? 1 : 0.4)
            EditorialHairline()

            EditorialRow(label: "Vocabulary lookup", toggle: $vocabLookup)
                .disabled(!aiEnabled).opacity(aiEnabled ? 1 : 0.4)
            EditorialHairline()

            stubRow(label: "Model", value: aiModel)
                .disabled(!aiEnabled).opacity(aiEnabled ? 1 : 0.4)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        EditorialList("Account") {
            EditorialRow(label: "Signed in as", value: signedInLabel)
            EditorialHairline()

            Button { showSignOutConfirm = true } label: {
                EditorialRow(label: "Sign out", danger: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Display-only row for an unimplemented setting. Renders the editorial
    /// chevron row but does nothing when tapped — once the underlying feature
    /// exists, swap this for a `NavigationLink` to its detail screen without
    /// touching call sites.
    private func stubRow(label: String, value: String) -> some View {
        EditorialRow(label: label, value: value, chevron: true)
    }

    private var syncProtocolName: String {
        switch env.authStore.loadActiveProtocol() {
        case .kosync: return "KOReader Sync"
        case .kobo:   return "Kobo Sync"
        }
    }

    /// Masked URL hint — last 8 chars of host. Avoids surfacing the full
    /// token-bearing path while still letting the user recognise their server.
    private var syncURLMasked: String {
        if let creds = try? env.authStore.load(),
           let host = creds.serverURL.host {
            return "••••" + String(host.suffix(8))
        }
        if let kobo = try? env.authStore.loadKobo(),
           let host = kobo.baseURL.host {
            return "••••" + String(host.suffix(8))
        }
        return "Not set"
    }

    private var signedInLabel: String {
        if let creds = try? env.authStore.load() {
            return creds.basic.username
        }
        if let kobo = try? env.authStore.loadKobo() {
            return kobo.baseURL.host ?? "Kobo"
        }
        return "Not signed in"
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Kios · v\(v) · build \(b)"
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let outcome = try await env.localImporter.import(from: url)
                switch outcome {
                case .imported(let book), .existing(let book):
                    env.openReader(book.id)
                }
            } catch let err as LocalImportError {
                importError = userFacingMessage(for: err)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func userFacingMessage(for error: LocalImportError) -> String {
        switch error {
        case .unsupportedFormat:
            return "Kios can only import EPUB files right now."
        case .readFailed(let detail):
            return "Couldn't read the file. \(detail)"
        case .parseFailed:
            return "This EPUB seems to be damaged."
        case .copyFailed(let detail):
            return "Couldn't save the file. \(detail)"
        case .noTitle:
            return "This EPUB has no title metadata and can't be imported."
        }
    }
}
