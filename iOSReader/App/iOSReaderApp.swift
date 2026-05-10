import SwiftUI
import SwiftData

@main
struct iOSReaderApp: App {
    @State private var environment: AppEnvironment

    init() {
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
        }
    }
}
