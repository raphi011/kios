import SwiftUI

struct BrowseRootView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var rootLoader: FeedLoader?
    @State private var query: String = ""
    @State private var path = NavigationPath()
    @State private var searchError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let loader = rootLoader {
                    FeedView(feedURL: loader.initialURL)
                        .navigationTitle("Browse")
                } else {
                    ProgressView().task { setup() }
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                FeedView(feedURL: route.url)
                    .navigationTitle("Results: \(route.query)")
            }
            .navigationDestination(for: OpenReaderRoute.self) { route in
                ReaderView(bookID: route.bookID)
            }
            .environment(\.openBook, { book in
                path.append(OpenReaderRoute(bookID: book.id))
            })
        }
        .modifier(ConditionalSearchable(
            shouldShow: rootLoader?.searchDescriptorURL != nil,
            query: $query,
            onSubmit: { submitSearch() }
        ))
        .alert("Search failed", isPresented: .constant(searchError != nil),
               actions: { Button("OK") { searchError = nil } },
               message: { Text(searchError ?? "") })
    }

    private func setup() {
        guard let opds = env.opds, let creds = try? env.authStore.load() else { return }
        let url = creds.serverURL.appendingPathComponent("opds/")
        let loader = FeedLoader(opds: opds, initialURL: url)
        rootLoader = loader
        Task { await loader.loadFirstPage() }
    }

    private func submitSearch() {
        guard let descriptorURL = rootLoader?.searchDescriptorURL,
              let opds = env.opds else { return }
        let q = query
        Task {
            do {
                let descriptor = try await opds.fetchSearchDescriptor(at: descriptorURL)
                guard let resolved = descriptor.resolve(query: q) else { return }
                await MainActor.run {
                    path.append(SearchRoute(url: resolved, query: q))
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                }
            }
        }
    }
}

struct SearchRoute: Hashable {
    let url: URL
    let query: String
}

struct OpenReaderRoute: Hashable {
    let bookID: UUID
}

// MARK: - openBook environment value

struct OpenBookActionKey: EnvironmentKey {
    static let defaultValue: (Book) -> Void = { _ in }
}

extension EnvironmentValues {
    var openBook: (Book) -> Void {
        get { self[OpenBookActionKey.self] }
        set { self[OpenBookActionKey.self] = newValue }
    }
}

/// Conditionally attach `.searchable` only when the root feed has advertised
/// a search descriptor URL. iOS shows the affordance whenever the modifier is
/// present, so we can't keep it always-on without `.searchable` lighting up
/// even on servers that don't support search.
private struct ConditionalSearchable: ViewModifier {
    let shouldShow: Bool
    @Binding var query: String
    let onSubmit: () -> Void

    func body(content: Content) -> some View {
        if shouldShow {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
                .onSubmit(of: .search) { onSubmit() }
        } else {
            content
        }
    }
}
