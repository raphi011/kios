import SwiftUI
import os

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    /// Pinned to prevent TabView from resetting to the first tab when the
    /// parent re-renders during a child's first appearance.
    @State private var selectedTab: Int = 0

    @State private var coordinator = BookOpenCoordinator.shared

    var body: some View {
        @Bindable var router = env.router

        // No first-run gate: the app ships with seeded books and supports
        // local EPUB imports, so it's usable without sync. Users who want
        // sync configure it via Settings; until then, sources.contexts has no
        // entries with a sync service and the flush loop is a no-op.
        TabView(selection: $selectedTab) {
            HomeRootView()
                .tabItem { Label("Read", systemImage: "book.pages") }
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
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for ctx in env.sources.contexts.values {
                            guard let sync = ctx.sync else { continue }
                            group.addTask { await sync.flushAllPending() }
                        }
                    }
                }
            }
            if newPhase == .background {
                env.stats.sessionDidClose(reason: .backgrounded)
            }
        }
        // After the user configures a server source in Settings, jump them to
        // Library — that's where the freshly refreshed catalog lives.
        .onChange(of: env.sources.contexts.contains(where: { $0.value.sync != nil })) { _, hasSync in
            if hasSync { selectedTab = 1 }
        }
        .onChange(of: coordinator.pendingBookID) { _, newValue in
            guard newValue != nil, let id = coordinator.consume() else { return }
            env.router.openReader(id)
        }
        .task {
            await env.seedSampleBooksIfNeeded()
        }
        .onAppear {
            // Cold launch: the intent may have set `pendingBookID` before
            // RootView mounted. Consume it on first appear.
            if let id = coordinator.consume() {
                env.router.openReader(id)
            }
        }
        .fullScreenCover(item: $router.activeReader) { route in
            ReaderView(bookID: route.id)
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "epub" else { return }
            Task { await handleOpenURL(url) }
        }
    }

    private func handleOpenURL(_ url: URL) async {
        do {
            let outcome = try await env.localImporter.import(
                from: url,
                localSource: env.localSource
            )
            switch outcome {
            case .imported(let book), .existing(let book):
                env.router.openReader(book.id)
            }
        } catch {
            Logger.importFlow.error(
                "openURL import failed: \(error.localizedDescription, privacy: .public)"
            )
            // .onOpenURL has no UI to alert from. Swallow — file is left
            // alone, no row inserted. Future improvement: bridge errors
            // back to a toast surface.
        }
    }
}
