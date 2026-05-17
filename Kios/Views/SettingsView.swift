import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Core

/// Editorial settings screen. Matches the design package's `EditorialSettings`:
/// Reading / Library & sync / AI assistant / Account sections in grouped
/// inset cards under a big serif **Settings** title, with a version footer.
///
/// Library & sync shows the configured Sources list (each row navigates to
/// SourceDetailView) plus an Add Source link and global toggles. Sources are
/// added/removed individually — there is no global sign-out.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext

    // Reading — display-only stubs until the reader settings model lands.
    @State private var defaultTheme = "Paper"
    @State private var defaultFont = "Newsreader"
    @State private var pageTransition = "Slide"
    @State private var tapZones = "Edges"

    /// Mirrors the AppStorage flag read by ReaderView. Default-on so first
    /// launch matches the reader's behaviour without the user having to opt
    /// in.
    @AppStorage("reader.hapticChapterEnabled") private var hapticChapterEnabled: Bool = true

    // Library & sync — toggles persist in-session only.
    @State private var syncOverCellular = false

    // File importer (Import EPUB row).
    @State private var showFileImporter = false
    @State private var importError: String?

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
                librarySyncSection
                aiSection
                cacheSection

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
            EditorialHairline()
            EditorialRow(
                label: "Chapter haptics",
                detail: "Subtle tap when finishing a chapter",
                toggle: $hapticChapterEnabled
            )
        }
    }

    // MARK: - Library & sync

    private var librarySyncSection: some View {
        EditorialList(
            "Library & sync",
            footer: "Sources sync your library from CWA / calibre-web / public OPDS catalogs. Add as many as you like."
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

            SourcesList()
            EditorialHairline()

            NavigationLink {
                AddSourceView()
            } label: {
                EditorialRow(
                    label: "Add source",
                    detail: "kosync, Kobo, or OPDS",
                    chevron: true
                )
            }
            .buttonStyle(.plain)
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

    // MARK: - Helpers

    /// Display-only row for an unimplemented setting. Renders the editorial
    /// chevron row but does nothing when tapped — once the underlying feature
    /// exists, swap this for a `NavigationLink` to its detail screen without
    /// touching call sites.
    private func stubRow(label: LocalizedStringKey, value: String) -> some View {
        EditorialRow(label: label, value: value, chevron: true)
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
                let outcome = try await env.localImporter.import(
                    from: url,
                    localSource: env.localSource
                )
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

// MARK: - Sources list

/// Inline Sources list for the Library & sync section. Fetches all sources
/// sorted by `sortOrder` and renders one editorial row per source; each row
/// pushes `SourceDetailView`. When there are no server sources yet, the list
/// is empty (the "Add source" row below it serves as the CTA).
private struct SourcesList: View {
    @Query(sort: [SortDescriptor(\Source.sortOrder)]) private var sources: [Source]

    var body: some View {
        ForEach(sources) { source in
            NavigationLink {
                SourceDetailView(source: source)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                            .font(EditorialTheme.sans(size: 17))
                            .foregroundStyle(EditorialTheme.ink)
                    }
                    Spacer(minLength: 8)
                    Text(kindLabel(source.kind))
                        .font(EditorialTheme.mono(size: 13))
                        .foregroundStyle(EditorialTheme.muted)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                .padding(.horizontal, EditorialTheme.rowSidePad)
                .padding(.vertical, 12)
                .frame(minHeight: EditorialTheme.cellMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if source != sources.last {
                EditorialHairline()
            }
        }
    }

    private func kindLabel(_ kind: SourceKind) -> String {
        switch kind {
        case .local: return "Local"
        case .opdsReadOnly: return "OPDS"
        case .kosync: return "kosync"
        case .kobo: return "Kobo"
        }
    }
}
