import SwiftUI
import SwiftData
import Core

/// Editorial settings screen. Matches the design package's `EditorialSettings`:
/// Reading / Library & sync sections in grouped inset cards under a big serif
/// **Settings** title, with a version footer.
///
/// Library & sync shows the configured Sources list (each row navigates to
/// SourceDetailView) plus an Add Source link and global toggles. Sources are
/// added/removed individually — there is no global sign-out.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// Mirrors the AppStorage key the reader reads to override Readium's
    /// `EPUBPreferences.fontFamily`. Empty string = "Publisher default"
    /// (no override). Selection happens on `FontFamilyPickerView`.
    @AppStorage(.readerFontFamily) private var fontFamily: String

    /// Same AppStorage key the reader's pinch gesture writes — this is
    /// the second entry point onto the same value, exposed for users
    /// who don't discover pinch. Steps in 10% increments to stay aligned
    /// with `FontSizeStep` so pinch and stepper never disagree.
    @AppStorage(.readerFontSizePct) private var fontSizePct: Int

    /// Mirrors the AppStorage flag read by ReaderView. Default-on so first
    /// launch matches the reader's behaviour without the user having to opt
    /// in.
    @AppStorage(.readerHapticChapterEnabled) private var hapticChapterEnabled: Bool

    /// User's theme choice. Mirrors the AppStorage key the app root reads
    /// to apply `.preferredColorScheme(_:)`. Same value drives the EPUB
    /// page theme via `ReaderThemeResolution.resolve(...)`.
    @AppStorage(.appearance) private var appearance: AppearancePreference

    // Library & sync — toggles persist in-session only.
    @State private var syncOverCellular = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EditorialNavBar(title: "Settings")

                appearanceSection           // new
                readingSection
                librarySyncSection

                Text(versionLine)
                    .editorialEyebrow()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                Color.clear.frame(height: 110)   // tab-bar breathing
            }
        }
        .background(EditorialTheme.bg)
        .navigationBarHidden(true)
    }

    // MARK: - Appearance

    /// Top-level theme switch. Coupled — flips both the app chrome and the
    /// EPUB page theme. Segmented because there are exactly three options;
    /// if Sepia is ever added, promote to a NavigationLink → detail view.
    private var appearanceSection: some View {
        EditorialList("Appearance") {
            HStack(spacing: 12) {
                Text("Theme")
                    .font(EditorialTheme.sans(size: 17))
                    .foregroundStyle(EditorialTheme.ink)
                Spacer(minLength: 8)
                Picker("", selection: $appearance) {
                    Text("System").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Theme")
                .frame(maxWidth: 220)
            }
            .padding(.horizontal, EditorialTheme.rowSidePad)
            .padding(.vertical, 8)
            .frame(minHeight: EditorialTheme.cellMin)
        }
    }

    // MARK: - Reading

    private var readingSection: some View {
        EditorialList("Reading") {
            NavigationLink {
                FontFamilyPickerView()
            } label: {
                EditorialRow(
                    label: "Default font",
                    value: ReaderFontFamily.from(rawValue: fontFamily).displayName,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            EditorialHairline()
            fontSizeRow
            EditorialHairline()
            EditorialRow(
                label: "Chapter haptics",
                detail: "Subtle tap when finishing a chapter",
                toggle: $hapticChapterEnabled
            )
        }
    }

    /// Inline stepper that walks `fontSizePct` along the same 10% grid
    /// that pinch snaps onto (`FontSizeStep.min...max`, step 10). The
    /// displayed value is point-converted via `ReaderFontSize` so the
    /// number reads as type, not as a multiplier.
    private var fontSizeRow: some View {
        Stepper(
            value: $fontSizePct,
            in: FontSizeStep.min...FontSizeStep.max,
            step: FontSizeStep.step
        ) {
            HStack(spacing: 12) {
                Text("Font size")
                    .font(EditorialTheme.sans(size: 17))
                    .foregroundStyle(EditorialTheme.ink)
                Spacer(minLength: 8)
                Text("\(ReaderFontSize.pt(forPct: fontSizePct))pt")
                    .font(EditorialTheme.mono(size: 13))
                    .foregroundStyle(EditorialTheme.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, EditorialTheme.rowSidePad)
        .padding(.vertical, 8)
        .frame(minHeight: EditorialTheme.cellMin)
    }

    // MARK: - Library & sync

    private var librarySyncSection: some View {
        EditorialList(
            "Library & sync",
            footer: "Sources sync your library from CWA / calibre-web / public OPDS catalogs. Add as many as you like."
        ) {
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

    // MARK: - Helpers

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "Kios · v\(v) · build \(b)"
    }

}

// MARK: - Sources list

/// Inline Sources list for the Library & sync section. Fetches all sources
/// sorted by `sortOrder` and renders one editorial row per server source;
/// each row pushes `SourceDetailView`. The local source is filtered out —
/// it always exists for sideloaded EPUBs and has no per-source config, so
/// surfacing it here would just be noise. When there are no server sources
/// yet, the list is empty (the "Add source" row below it serves as the CTA).
private struct SourcesList: View {
    @Query(sort: [SortDescriptor(\Source.sortOrder)]) private var sources: [Source]

    private var serverSources: [Source] {
        sources.filter { $0.kind != .local }
    }

    var body: some View {
        ForEach(serverSources) { source in
            NavigationLink {
                SourceDetailView(source: source)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(urlLabel(source.serverURL))
                            .font(EditorialTheme.sans(size: 17))
                            .foregroundStyle(EditorialTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !source.displayName.isEmpty {
                            Text(source.displayName)
                                .font(EditorialTheme.sans(size: 13))
                                .foregroundStyle(EditorialTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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
            if source != serverSources.last {
                EditorialHairline()
            }
        }
    }

    /// URL identifies the source; the user-typed display name is
    /// secondary. Prefer host + port to keep the row scannable — full
    /// URLs with scheme and path bloat the line without adding info
    /// (the source's kind already implies the protocol).
    private func urlLabel(_ url: URL?) -> String {
        guard let url else { return "—" }
        if let host = url.host(percentEncoded: false) {
            if let port = url.port { return "\(host):\(port)" }
            return host
        }
        return url.absoluteString
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
