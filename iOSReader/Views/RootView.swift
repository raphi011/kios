import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // First-run gate: if there is no OPDSClient (no credentials), force Settings.
        if env.opds == nil {
            NavigationStack { SettingsView() }
        } else {
            TabView {
                BrowseRootView()
                    .tabItem { Label("Browse", systemImage: "books.vertical") }
                DownloadedRootView()
                    .tabItem { Label("Downloaded", systemImage: "arrow.down.circle") }
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}
