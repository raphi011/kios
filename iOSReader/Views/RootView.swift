import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Pinned to prevent TabView from resetting to the first tab when the
    /// parent re-renders during a child's first appearance.
    @State private var selectedTab: Int = 0

    var body: some View {
        @Bindable var env = env

        Group {
            // First-run gate: any active-protocol credentials present rebuilds
            // SyncService. Library is a SwiftData @Query and shows for both
            // protocols — it's safe even when `env.opds == nil` (Kobo mode).
            if env.sync == nil {
                NavigationStack { SettingsView() }
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
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await env.sync?.flushAllPending() }
                    }
                }
            }
        }
        .fullScreenCover(item: $env.activeReader) { route in
            ReaderView(bookID: route.id)
        }
    }
}
