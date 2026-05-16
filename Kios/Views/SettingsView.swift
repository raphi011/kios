import SwiftUI
import SwiftData
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
    @Environment(\.modelContext) private var modelContext

    // Reading — display-only stubs until the reader settings model lands.
    @State private var defaultTheme = "Paper"
    @State private var defaultFont = "Newsreader"
    @State private var pageTransition = "Slide"
    @State private var tapZones = "Edges"

    // Library & sync — toggles persist in-session only.
    @State private var syncOverCellular = false

    // File importer (Import EPUB row).
    @State private var showFileImporter = false
    @State private var importError: String?

    // Sign-out confirmation.
    @State private var showSignOutConfirm = false

    // First-enable explainer sheet — shown the first time the master AI
    // toggle is flipped on. Subsequent toggles are silent.
    @State private var showFirstEnableSheet = false

    /// Bumped after operations that mutate on-disk model state (delete,
    /// download completion). The asset store reads the filesystem on each
    /// access but isn't `@Observable`, so we need a manual nudge to make
    /// SwiftUI re-evaluate `aiAvailability` and refresh the download cell.
    @State private var modelStateVersion = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EditorialNavBar(title: "Settings")

                readingSection
                LanguagePicker()
                librarySyncSection
                aiSection
                cacheSection
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
        .sheet(isPresented: $showFirstEnableSheet) {
            AIFirstEnableSheet(
                availability: AIAvailability.resolve(
                    userEnabled: true,
                    preferredEngine: env.aiSettings.preferredEngine,
                    capability: .current,
                    assetStore: env.aiAssetStore,
                    downloads: env.aiDownloadService
                )
            ) {
                showFirstEnableSheet = false
            }
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

    /// Live availability snapshot. Cheap to compute per render —
    /// `installationStatus(for:)` stats files and `currentDownload()` reads a
    /// single MainActor-isolated property. Recomputing here keeps the picker
    /// and download cell in lockstep with `aiSettings.preferredEngine` and
    /// `aiDownloadService.progress` without an intermediate cache.
    private var aiAvailability: AIAvailability {
        AIAvailability.resolve(
            userEnabled: env.aiSettings.featuresEnabled,
            preferredEngine: env.aiSettings.preferredEngine,
            capability: .current,
            assetStore: env.aiAssetStore,
            downloads: env.aiDownloadService
        )
    }

    private var featuresEnabledBinding: Binding<Bool> {
        Binding(
            get: { env.aiSettings.featuresEnabled },
            set: { newValue in
                env.aiSettings.featuresEnabled = newValue
                guard newValue else { return }
                // First flip-on shows the explainer sheet once.
                if !env.aiSettings.didShowFirstEnableSheet {
                    showFirstEnableSheet = true
                    env.aiSettings.didShowFirstEnableSheet = true
                }
                // On devices without 8 GB of RAM, snap preference to FM so
                // the picker never advertises an engine the device can't run.
                if !DeviceCapability.current.supportsGemma4_e4b {
                    env.aiSettings.preferredEngine = .foundationModels
                }
            }
        )
    }

    private var preferredEngineBinding: Binding<AIEngine> {
        Binding(
            get: { env.aiSettings.preferredEngine },
            set: { env.aiSettings.preferredEngine = $0 }
        )
    }

    private var allowCellularBinding: Binding<Bool> {
        Binding(
            get: { env.aiSettings.allowCellularDownload },
            set: { env.aiSettings.allowCellularDownload = $0 }
        )
    }

    private var aiSection: some View {
        EditorialList(
            "AI assistant",
            footer: "Summarize chapters and ask about selected text — entirely on-device. Disable the master switch to make no AI calls at all."
        ) {
            EditorialRow(label: "Enable AI features", toggle: featuresEnabledBinding)

            if env.aiSettings.featuresEnabled {
                EditorialHairline()
                AIEnginePicker(
                    availability: aiAvailability,
                    preferredEngine: preferredEngineBinding
                )
                .padding(.horizontal, EditorialTheme.rowSidePad)
                .padding(.vertical, 12)

                EditorialHairline()
                EditorialRow(
                    label: "Device RAM",
                    value: DeviceCapability.current.ramDisplay
                )

                if env.aiSettings.preferredEngine == .gemma4_e4b
                    && DeviceCapability.current.supportsGemma4_e4b {
                    EditorialHairline()
                    ModelDownloadCell(
                        asset: ModelCatalog.gemma4_e4b,
                        status: env.aiAssetStore.installationStatus(for: ModelCatalog.gemma4_e4b),
                        progress: env.aiDownloadService.progress,
                        onDownload: {
                            Task {
                                await env.aiDownloadService.startDownload(
                                    of: ModelCatalog.gemma4_e4b,
                                    allowCellular: env.aiSettings.allowCellularDownload
                                )
                            }
                        },
                        onCancel: { env.aiDownloadService.cancel() },
                        onDelete: {
                            try? env.aiAssetStore.delete(ModelCatalog.gemma4_e4b)
                            modelStateVersion += 1
                        }
                    )
                    .id(modelStateVersion)
                    .padding(.horizontal, EditorialTheme.rowSidePad)
                    .padding(.vertical, 12)

                    EditorialHairline()
                    EditorialRow(
                        label: "Allow cellular download",
                        toggle: allowCellularBinding
                    )
                }
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        EditorialList("Cache") {
            Button(role: .destructive) {
                clearAllChapterSummaries()
            } label: {
                EditorialRow(label: "Clear cached summaries", danger: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// Wipes every persisted `ChapterSummary` row. Best-effort: failures are
    /// swallowed because the user can simply retry — no data integrity risk
    /// since rows are derivable from chapter text on demand.
    private func clearAllChapterSummaries() {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<ChapterSummary>())
            for row in rows { modelContext.delete(row) }
            try modelContext.save()
        } catch {
            // Best-effort; user can retry. Not surfaced because the failure
            // mode (corrupt store) is already escalated elsewhere.
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
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
