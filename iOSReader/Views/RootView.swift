import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
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

/// Stub — replaced by Task 5.3.
struct LibraryView: View {
    var body: some View { Text("Library (stub)") }
}
