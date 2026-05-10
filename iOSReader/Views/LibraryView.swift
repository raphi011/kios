import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [BookListItem] = []
    @State private var refreshing = false
    @State private var refreshError: String?

    var body: some View {
        List {
            if let refreshError {
                Section {
                    Text(refreshError).foregroundStyle(.orange)
                }
            }
            ForEach(items) { item in
                NavigationLink {
                    BookDetailView(bookID: item.id)
                } label: {
                    BookRow(item: item)
                }
            }
        }
        .navigationTitle("Library")
        .refreshable { await refresh() }
        .task {
            // First load.
            await refresh()
            // Live subscribe — re-renders when LibraryService yields.
            guard let stream = env.library?.observableItems else { return }
            for await new in stream { items = new }
        }
    }

    private func refresh() async {
        guard let library = env.library, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try await library.refresh()
            items = library.items
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

private struct BookRow: View {
    let item: BookListItem

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.title).font(.headline)
                if !item.authors.isEmpty {
                    Text(item.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            stateIcon
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .remote:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
        case .downloading(let p):
            ProgressView(value: p)
                .frame(width: 60)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// Stub — replaced by Task 5.4.
struct BookDetailView: View {
    let bookID: UUID
    var body: some View { Text("Book detail (stub) for \(bookID)") }
}
