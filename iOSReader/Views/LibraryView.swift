import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var refreshing = false
    @State private var refreshError: String?

    var body: some View {
        List {
            if let refreshError {
                Section {
                    Text(refreshError).foregroundStyle(.orange)
                }
            }
            ForEach(env.library?.items ?? []) { item in
                NavigationLink {
                    BookDetailView(bookID: item.id)
                } label: {
                    BookRow(item: item)
                }
            }
        }
        .navigationTitle("Library")
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func refresh() async {
        guard let library = env.library, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try await library.refresh()
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

