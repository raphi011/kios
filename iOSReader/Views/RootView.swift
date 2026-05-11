import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // First-run gate: if there is no OPDSClient (no credentials), force Settings.
        if env.opds == nil {
            NavigationStack { SettingsView() }
        } else {
            TabView {
                HomeRootView()
                    .tabItem { Label("Home", systemImage: "house") }
                BrowseRootView()
                    .tabItem { Label("Browse", systemImage: "books.vertical") }
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await env.sync?.flushAllPending() }
                }
            }
        }
    }
}
