import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Pinned to prevent TabView from resetting to the first tab when the
    /// parent re-renders during a child's first appearance (BrowseRootView's
    /// setup() spins up a FeedLoader and a Task on .task, which in some
    /// scenarios bubbles into a re-evaluation of this body and drops the
    /// implicit selection back to Home).
    @State private var selectedTab: Int = 0

    var body: some View {
        @Bindable var env = env

        Group {
            // First-run gate: any active-protocol credentials present rebuilds
            // SyncService. Browse is OPDS-specific and only shows in kosync mode;
            // Kobo's catalog flows through SyncService/KoboBackend, not OPDS.
            if env.sync == nil {
                NavigationStack { SettingsView() }
            } else {
                TabView(selection: $selectedTab) {
                    HomeRootView()
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(0)
                    if env.opds != nil {
                        BrowseRootView()
                            .tabItem { Label("Browse", systemImage: "books.vertical") }
                            .tag(1)
                    }
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
