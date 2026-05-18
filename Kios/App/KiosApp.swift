import SwiftUI
import SwiftData

@main
struct KiosApp: App {
    @State private var environment: AppEnvironment

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            directory: nil
        )
        Migrations.applyMultiSourceWipeIfNeeded()
        do {
            _environment = State(initialValue: try AppEnvironment())
        } catch {
            fatalError("AppEnvironment failed to initialize: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.modelContainer)
                .environment(\.modelContext, environment.modelContext)
        }
    }
}
