import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Pinned to prevent TabView from resetting to the first tab when the
    /// parent re-renders during a child's first appearance.
    @State private var selectedTab: Int = 0

    @State private var coordinator = BookOpenCoordinator.shared

    var body: some View {
        @Bindable var env = env

        Group {
            // First-run gate: any active-protocol credentials present rebuilds
            // SyncService. Library is a SwiftData @Query and shows for both
            // protocols — it's safe even when `env.opds == nil` (Kobo mode).
            if env.sync == nil {
                NavigationStack { SyncSetupView() }
            } else {
                TabView(selection: $selectedTab) {
                    HomeRootView()
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(0)
                    LibraryRootView()
                        .tabItem { Label("Library", systemImage: "books.vertical") }
                        .tag(1)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(2)
                }
                .editorialTabBarStyling()
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await env.sync?.flushAllPending() }
                    }
                    if newPhase == .background {
                        env.stats.sessionDidClose(reason: .backgrounded)
                    }
                }
            }
        }
        // First-run completion: when SyncService flips from nil to non-nil
        // (the user finished configuring a protocol in Settings), drop them
        // on Library — that's where the freshly refreshed catalog lives, and
        // Home would be empty until they download something.
        .onChange(of: env.sync != nil) { _, hasSync in
            if hasSync { selectedTab = 1 }
        }
        .onChange(of: coordinator.pendingBookID) { _, newValue in
            guard newValue != nil, let id = coordinator.consume() else { return }
            env.openReader(id)
        }
        .task {
            await env.seedSampleBooksIfNeeded()
        }
        .onAppear {
            // Cold launch: the intent may have set `pendingBookID` before
            // RootView mounted. Consume it on first appear.
            if let id = coordinator.consume() {
                env.openReader(id)
            }
        }
        .fullScreenCover(item: $env.activeReader) { route in
            ReaderView(bookID: route.id)
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "epub" else { return }
            Task { await handleOpenURL(url) }
        }
    }

    private func handleOpenURL(_ url: URL) async {
        do {
            let outcome = try await env.localImporter.import(from: url)
            switch outcome {
            case .imported(let book), .existing(let book):
                env.openReader(book.id)
            }
        } catch {
            // .onOpenURL has no UI to alert from. Swallow — file is left
            // alone, no row inserted. Future improvement: bridge errors
            // back to a toast surface.
        }
    }
}
