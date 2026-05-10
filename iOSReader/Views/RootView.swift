import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            // First-run gate: env.library is set by AppEnvironment.bootIfCredentialsPresent
            // only when valid credentials are in the Keychain. Nil means no creds yet
            // (or the user just cleared them). If we add a Sign Out affordance later
            // this gate may need to differentiate first-run from sign-out.
            if env.library == nil {
                SettingsView()
            } else {
                LibraryView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
            }
        }
    }
}
